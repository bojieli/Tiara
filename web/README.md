# Tiara companion website

An interactive companion site for **Tiara: A Programmable Line-Rate ISA for
Remote Memory Access** (APNet 2026). It explains the thesis (the *Indirection
Wall*), the NIC architecture and abstractions, lets you **run the Tiara
instruction set in your browser**, and lets you **explore every evaluation
figure interactively**.

The centerpiece is a faithful, dependency-free in-browser port of the Tiara
toolchain:

| Module | Port of | Purpose |
|--------|---------|---------|
| `src/engine/isa.ts` | `sw/asm/tiara_isa.py` | byte-exact instruction encode/decode (BigInt) |
| `src/engine/asm.ts` | `sw/asm/tiara_asm.py` | two-pass `.tasm` assembler |
| `src/engine/vm.ts` | Verilator RTL behaviour | single-step execution engine + host-DRAM model + latency model |
| `src/engine/verifier.ts` | `sw/verifier/tiara_verifier.py` | termination + region-bounds static verification |
| `src/engine/cc.ts` | `sw/compiler/tiara_cc.py` | restricted-C → `.tasm` compiler |

## Fidelity

The TS engine is validated against the Python reference and the Verilator
simulator. `scripts/gen_golden.py` emits `src/engine/golden.json` (assembled
encodings + run vectors), and the test suite asserts the TS assembler produces
**byte-identical** encodings and the TS VM reproduces the simulator's
`r0..r3` results exactly.

```bash
npm install
npm test          # 143 tests across 9 files (see "Test coverage" below)
npm run dev       # local dev server
npm run build     # static build into dist/  (base: './', host anywhere)
```

To regenerate the golden vectors (requires the built Verilator sim at
`sim/verilator/build/Vtiara_nic_top`):

```bash
python3 scripts/gen_golden.py
```

## Test coverage

| File | Tests | What it covers |
|------|-------|----------------|
| `isa.test.ts` | 12 | encode/decode round-trips, imm sign-extension, addressing, widths |
| `asm.test.ts` | 19 | every mnemonic, labels, forward-only JUMP, LOOP body length, directives, errors |
| `vm.test.ts` | 37 | every ALU sub-op, 64-bit wrap, register-chained loads, loops (nested/zero), JUMP, CAS/CAA, async Memcpy + Wait, remote-RTT cost, flags, single-step trace events |
| `verifier.test.ts` | 9 | acceptance + every rejection (opaque LOAD, region escape, missing RET, backward JUMP, loop-nest, max_dynamic) |
| `cc.test.ts` | 15 | expressions/precedence, for/if, pointer deref (const+var index), builtins, region naming, compile errors |
| `engine.test.ts` | 36 | **golden vectors** — byte-exact encodings vs Python, exact run results vs Verilator, latency tolerance, C-pipeline integration |
| `presets.test.ts` | 5 | all 5 shipped operators assemble + verify + run to completion |
| `Playground.test.tsx` | 7 | DOM interaction — Step advances + highlights, register flashes, run-to-completion, verifier verdict, preset switch, C compile |
| `smoke.test.tsx` | 3 | full App / Playground / every chart render without throwing |

## Deployment

`npm run build` produces a fully static `dist/` with a relative base path, so
it can be served from any host or subdirectory — no backend, no GitHub Pages
wiring.
