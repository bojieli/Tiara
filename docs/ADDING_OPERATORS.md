# Adding a new operator

A 3-file pattern for any new Tiara operator.  The Tiara MP doesn't
need to know about your operator at compile time — it's just a binary
the host loads at registration.

## File 1 — `sw/operators/<name>.tasm`

Write the operator in Tiara assembly.  Cheat sheet:

| Instruction | Effect | Notes |
|---|---|---|
| `LOAD rd, [rs + imm]`  | `rd = MEM64(rs + imm)` | Sync; ~150 cycles for host DRAM, ~500 for remote |
| `STORE [rd + imm], rs` | `MEM64(rd + imm) = rs` | Sync |
| `MEMCPY rd, rs1, rs2, [ASYNC,] LEN=N` | bulk copy, optionally async | rd gets the status; ASYNC requires a later WAIT |
| `CAS rd, rs_addr, rs_exp, rs_new` | atomic compare-and-swap | rd gets the previous value |
| `CAA rd, rs_addr, rs_addend` | atomic compare-and-add | rd gets the previous value |
| `LI rd, imm`     | load immediate | imm is sign-extended |
| `ADDI rd, rs, imm` | add immediate | |
| `ADD rd, rs1, rs2` | add register | also SUB, AND, OR, XOR, MUL, SHL, SHR |
| `EQ rd, rs1, rs2` | rd = (rs1 == rs2) ? 1 : 0 | also LT, GE |
| `JUMP cond_reg, label` | forward-only branch on `cond_reg != 0` | |
| `LOOP count_reg, body_label` | iterate body `count_reg` times | bounded; verifier checks |
| `WAIT threshold` | block until in-flight async ≤ threshold | use 0 to drain |
| `RET rN`         | finish; `r1..r4` are returned | |

Conventions:
- `r0` is hard-wired to zero (RISC-V style).
- Arguments arrive in `r1..r8`; results return through `r1..r4`.
- A `LOAD` writes its result to a register that *the next instruction*
  can immediately use as the address — that's the whole point.

Use `.arg name reg` directives for documentation (the assembler ignores
them at runtime; the verifier reads them from the manifest).

Example: a 3-level page-table walk in 11 instructions —

```
  .arg vaddr r1
  .arg l1    r2
  SHRI r4, r1, 30
  ANDI r4, r4, 0x1FF
  SHLI r4, r4, 3
  ADD  r5, r2, r4
  LOAD r5, [r5 + 0]
  // ... two more levels ...
  RET  r5
```

## File 2 — `sw/operators/<name>.toml`

Tells the verifier what's legal.  Minimal:

```toml
[operator]
name        = "my_op"
version     = 1
max_dynamic = 256          # static upper bound on dynamic instr count

[[arguments]]
name   = "vaddr"
reg    = 1
bounds = [0, 0xFFFFFFFFFFFF]

[[arguments]]
name   = "l1_base"
reg    = 2
bounds = [0, 0x10000000]
device = 0
region = 1

[[regions]]
id     = 0
device = 0
name   = "client_recv_buffer"
size   = 0x80000000

[[regions]]
id     = 1
device = 0
name   = "page_tables"
size   = 0x20000000
```

`max_dynamic` is your verified worst-case instruction count.  The
verifier multiplies loop body × max-iterations and bails if you exceed
this.  Set it generously; it's a safety net.

`bounds` on each argument lets the verifier prove `LOAD/STORE/MEMCPY`
addresses stay inside a `region`.  Tight bounds give you static
safety; wide bounds yield a runtime check warning.

## File 3 — `eval/scripts/harness.py`

Add a `cmd_<name>(args)` function and a sub-command.  Pattern (~60
lines, see `cmd_moe()` for a recent template):

```python
def cmd_my_workload(args):
    tasm = ROOT / "sw" / "operators" / "<name>.tasm"
    _, op_bin = build_operator(tasm)
    seed_words = [...]   # whatever your operator reads
    with tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False) as f:
        f.write("\n".join(f"{w:016x}" for w in seed_words))
        seed = Path(f.name)
    try:
        r = run_sim(op_bin, args=[arg0, arg1, ...], dma_seed=seed)
    finally:
        seed.unlink(missing_ok=True)
    print(f"latency = {r.latency_us:.2f} µs")
    if args.out:
        Path(args.out).write_text(f"# my_workload\n{r.latency_us:.2f}\n")
    return 0
```

Wire it into `main()` with one `subparsers.add_parser` line.

## File 4 (optional) — `eval/scripts/plots.py`

If you want a publication-ready plot, add `plot_<name>(plt)` that
reads `eval/results/<name>.dat` and emits a PDF/EPS/PNG.

## Run it

```bash
python3 sw/asm/tiara_asm.py     sw/operators/<name>.tasm
python3 sw/verifier/tiara_verifier.py \
    sw/operators/<name>.tasm sw/operators/<name>.toml
sim/verilator/build/Vtiara_nic_top \
    --op sw/operators/<name>.bin \
    --args ARG0,ARG1,ARG2,...

# Or via the harness:
python3 eval/scripts/harness.py <name>
```

## Add it to CI

Edit `.github/workflows/ci.yml` to include your new harness command
under `make eval`.  Or add a unit test to `sw/tests/sim_test.py` that
calls `Vtiara_nic_top --op` directly.
