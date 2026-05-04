# Tiara C compiler

Tiara operators are short, structured kernels. Writing them by hand
in `.tasm` is fine for the five paper workloads, but the paper §3.4
calls for a higher-level source language: a restricted subset of C
(SCoP-style) that the operator author writes once and the compiler
lowers to Tiara assembly. This document covers the `tiara_cc.py`
compiler that ships with the repo.

## Why a restricted-C subset?

The Tiara verifier rejects any operator whose execution time, memory
footprint, or address range cannot be bounded statically. That rules
out unbounded loops, recursion, dynamic allocation, and pointer
arithmetic that escapes its declared region. The restricted subset
makes those constraints visible at the source level, so the compiler
can refuse to emit code that would be rejected downstream — a much
better experience than getting verifier errors against generated
assembly the user never wrote.

## Accepted constructs

| Feature | Notes |
|---|---|
| Function (one entry point) | Up to 8 args; declaration order maps to `r1..r8`. |
| 64-bit scalar locals | `uint64_t`, `int64_t`, `u64` — all alias `unsigned long`. |
| Pointer args | `uint64_t*` with naming convention `name_in_<region>_<size>`. The compiler emits `.region <region> <id>`. |
| Arithmetic | `+ - * & \| ^ << >>` (binary), `-` (unary), `!`. |
| Comparison | `==`, `<`, `>=` produce 0/1 for `JUMP`. |
| `for (int i = 0; i < N; i++)` | Lowers to `LOOP rN, body_label`. `N` may be a constant or any kernel arg. |
| `if (cond) { ... }` (no `else`) | Lowers to forward `JUMP`. |
| `return expr;` | Places `expr` in `r1`, emits `RET r1`. |
| `tiara_andi(x, mask)` | Required after every `LOAD` whose result becomes an address (verifier mandate). |
| `tiara_memcpy(dst, src, len, async_flag)` | `MEMCPY` with optional `ASYNC` flag. |
| `tiara_cas(addr, expected, new)` | Returns the old value. |
| `tiara_caa(addr, addend)` | Atomic add, returns old value. |
| `tiara_wait(threshold)` | Drains async copies. |
| `tiara_set_result(slot, value)` | Places `value` into one of `r1..r4` so the response packet returns it. |

## Rejected constructs

Anything outside the table above triggers a clean compile error with
a source location. Notably:

- recursion (the verifier already rejects it; the compiler catches it earlier);
- function pointers, indirect calls;
- dynamic memory (`malloc`, VLA);
- floating point;
- variadic functions;
- `goto`;
- `else`/`switch` (a future iteration may add these);
- pointer arithmetic on non-region pointers.

## Region naming convention

Pointer arg names follow a magic suffix `_in_<region_name>_<size>`,
where `<size>` is parsed as a 0x... or decimal integer:

```c
uint64_t walk(uint64_t* cur_in_graph_pool_0x80000000, uint64_t depth);
```

The compiler emits `.region graph_pool 0` and the rest of the assembler
+ verifier flow consume that. The size is later cross-checked against
the operator manifest's `[[regions]]` section.

## Example

```c
// graph_walk.c — depth-limited pointer chase.
uint64_t graph_walk(uint64_t* cur_in_graph_pool_0x80000000,
                    uint64_t  depth) {
    for (int i = 0; i < depth; i++) {
        uint64_t nxt    = cur_in_graph_pool_0x80000000[1];
        uint64_t curoff = tiara_andi(nxt, 0x7FFFFFF8);
        cur_in_graph_pool_0x80000000 = (uint64_t*)curoff;
    }
    uint64_t data = cur_in_graph_pool_0x80000000[0];
    tiara_set_result(2, (uint64_t)cur_in_graph_pool_0x80000000);
    return data;
}
```

Compiling and running:

```bash
$ python3 sw/compiler/tiara_cc.py sw/compiler/examples/graph_walk.c
wrote sw/compiler/examples/graph_walk.tasm (19 lines)

$ PYTHONPATH=sw/asm python3 sw/asm/tiara_asm.py \
      sw/compiler/examples/graph_walk.tasm
wrote sw/compiler/examples/graph_walk.bin (11 words, 88 bytes)
```

Run on the simulator:

```bash
./sim/verilator/build/Vtiara_nic_top \
    --op   sw/compiler/examples/graph_walk.bin \
    --dma  graph_seed.hex \
    --args 0,3
```

The integration test `sw/tests/compiler_test.py::test_graph_walk_runs`
exercises this exact flow.

## Internals (for hackers)

`tiara_cc.py` is a single-file Python module that uses `pycparser`
for the front-end (no LLVM dependency). The pipeline:

1. **Preprocess** — strip comments, OpenCL keywords, preprocessor
   directives, drop typedefs of standard types, inject a synthetic
   prelude that declares `uint64_t` etc.
2. **Parse** — pycparser's pure-Python C99 parser produces a `c_ast`.
3. **Lower** — recursive AST walk emits Tiara assembly. The walker
   keeps a `SymTable` mapping each variable to a register, and a
   per-block `opaque` set marking registers that came from `LOAD`
   without an intervening `ANDI`.
4. **Allocate** — linear-scan over `r9..r15` (post-arg scratch pool).
   Args claim `r1..r8` permanently; locals get the next free scratch
   register on first declaration, freed when out of scope.
5. **Peephole** — `tiara_andi(load_result, MASK)` clears the opaque
   bit on the destination so the verifier's region-inheritance rule
   kicks in for the canonical pointer pattern
   `LOAD → ANDI(mask) → ADD(region_base)`.

The output is plain `.tasm` text, so the rest of the toolchain is
unmodified. No new artifacts in the path.

## Limitations

- **Single function** — the compiler does not support helper
  functions yet. Inline anything you need.
- **No `else`** — guard your fast path with `if (cond) { ... }` and
  fall through.
- **Naive register allocation** — long-lived locals + many temps can
  overflow the 7-register scratch pool. Reduce locals or split the
  operator.
- **No LLVM** — the paper §3.4 mentions an LLVM front-end. We chose
  pycparser to keep the dependency surface small (no clang/LLVM build);
  the IR boundary is `Op` (an emitted assembly line) rather than LLVM
  IR. A future LLVM port is straightforward but is multi-week work.
