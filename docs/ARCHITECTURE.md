# Tiara NIC Architecture

This document describes the on-NIC implementation referenced by §3 of
the paper. It complements `docs/ISA.md` (the binary contract) with the
microarchitectural choices made in `rtl/tiara_nic`.

## Block diagram

```
                       ┌────────────────────────────────────────────┐
   Network ──RDMA──▶  │  RDMA Engine                               │
                       └────────────┬───────────────────────────────┘
                                    │
                                    ▼
                       ┌────────────────────────────────────────────┐
                       │  Task Dispatcher                           │
                       │  (matches operator_id, allocates a free MP)│
                       └────────────┬───────────────────────────────┘
                                    │
                  ┌─────────────────┼─────────────────┐
                  ▼                 ▼                 ▼
              ┌───────┐         ┌───────┐         ┌───────┐
              │  MP₀  │   ...   │  MPₖ  │   ...   │  MP₇  │
              │ regs  │         │ regs  │         │ regs  │
              │ ALU   │         │ ALU   │         │ ALU   │
              │ IStore│         │ IStore│         │ IStore│
              └───┬───┘         └───┬───┘         └───┬───┘
                  └───────────┬─────┴─────────────────┘
                              ▼
                    ┌───────────────────┐
                    │ Memory Subsystem  │
                    │  PCIe DMA + RDMA  │
                    └───────┬───────────┘
                            ▼
                       Host DRAM
```

The RTL in this repo instantiates a **single MP** in
`tiara_nic_top.sv` for cycle-accurate, per-MP characterisation. Scaling
to 8 MPs is mechanical (replicate the `u_mp` instance and route all
their `tiara_mem_if` interfaces through an arbiter). The throughput
numbers in the paper are derived from `eval/scripts/baselines.py` once
single-MP latency is measured.

## Memory processor pipeline

The MP is a small scalar core. It is **not** pipelined; instructions
execute sequentially with one instruction in flight at a time. This is
deliberate: register-chained loads (the key Tiara feature) require the
loaded value to be visible to the next instruction's address operand,
which is trivially satisfied when the next instruction does not begin
fetch until the previous LOAD's result has been committed to the
register file.

States:

| State        | Purpose                                                        |
|--------------|----------------------------------------------------------------|
| `S_IDLE`     | waiting for `task_start`                                       |
| `S_FETCH1`   | argument loading (8 cycles) → fetch instruction word 0         |
| `S_FETCH1_W` | wait for istore read response                                  |
| `S_FETCH2`   | issue read for the second word of MEMCPY/CAS/CAA               |
| `S_FETCH2_W` | wait for the second-word read                                  |
| `S_EXECUTE`  | decode + dispatch (combinational), update PC + commit writeback |
| `S_MEM_WAIT` | block until the memory subsystem returns (LOAD/sync MEMCPY/CAS) |
| `S_MEM_ASYNC`| latch async accept and continue                                |
| `S_WAIT`     | spin until `inflight ≤ wait_threshold`                         |
| `S_DONE`     | latch return values, raise `task_done`                         |

PC advance is centralised in `adjusted_next_pc`: it composes the
linear successor (`+1` or `+2` for two-word ops), an explicit
target from `JUMP`/`LOOP`, and the loop-stack snap-back. This avoids
duplicating the loop-end check at every PC-advancing site.

## Loop stack

`tiara_loop_stack.sv` is a depth-8 LIFO of `(begin_pc, end_pc, remaining)`.
On `LOOP(M, N)`: the MP pushes `(pc+1, pc+1+N, M-1)`. After every
PC-advancing instruction, if the next PC equals `top.end_pc`, the
top frame either decrements `remaining` and snaps back to `top.begin_pc`,
or pops if `remaining == 0`.

Forward-only `JUMP` plus bounded `LOOP` give the verifier a closed-form
upper bound on dynamic step count. Backward branches are rejected at
registration time.

## Memory subsystem

The unified 64-bit address `[device_id : 16][region_id : 16][offset : 32]`
fans out to:

* **PCIe DMA** (device 0) — `tiara_pcie_dma.sv`. Functional model with
  configurable `LATENCY_CYCLES`. Default 150 cycles ≈ 0.75 µs at
  200 MHz, calibrated against the U50 prototype.
* **RDMA engine** (device > 0) — `tiara_rdma_engine.sv`. Functional
  model with configurable `RTT_CYCLES`. Default 500 cycles ≈ 2.5 µs.

Both engines model an in-flight slot ring. The MP issues at most one
operation per cycle and stalls in `S_MEM_WAIT` until completion.

## Static verification (paper §3.3)

`sw/verifier/tiara_verifier.py` performs three checks at registration
time:

1. **Termination.** Walks the instruction list, maintaining a stack
   of `(end_pc, max_iters)` loop frames. The total dynamic instruction
   count is `Σ outer_multiplier`; rejected if it exceeds the manifest's
   `max_dynamic`.
2. **Memory bounds.** Interval analysis over registers. Argument
   bounds come from the manifest; `LOAD` results are opaque (registered
   as a soft warning that the runtime region check enforces).
   Addresses must lie within a declared region.
3. **Resource caps.** Loop nesting ≤ 8, in-flight async ≤ 32,
   instructions ≤ 1024.

The verifier emits a SHA-256 digest of the assembled binary so the
runtime loader can prove it loaded the binary that was verified.

## Calibration

| Parameter                     | Value (default)        | Source                                  |
|-------------------------------|------------------------|-----------------------------------------|
| Clock period                  | 5 ns (200 MHz)         | Alveo U50 typical                       |
| Local DRAM access (PCIe DMA)  | 150 cycles ≈ 0.75 µs   | Tiara prototype (paper §4.1)            |
| RDMA round-trip               | 500 cycles ≈ 2.5 µs    | Connect-X / TOR switch (paper §4.1)     |
| MP register file              | 16 × 64 bit            | Paper §3.2                               |
| Instruction store             | 1024 × 64 bit (BRAM)   | Paper §3.2                               |
| Loop stack depth              | 8                      | Paper §3.3                               |
| Max in-flight async per task  | 32                     | Paper §3.3                               |

All calibration parameters live as Verilog parameters on the
top-level. Override at sim time by passing `-G LOCAL_LATENCY_CYCLES=200`
etc. through Verilator's `-Gname=value` flag (see
`sim/verilator/Makefile`).
