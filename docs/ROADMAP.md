# Roadmap

## Status (current)

| Component | Status |
|---|---|
| Tiara ISA + assembler + verifier | done |
| Tiara core RTL (MP, regfile, ALU, istore, loop stack, dispatcher) | done |
| Cycle-accurate Verilator simulator | done — 27/27 unit tests pass |
| Four paper workloads (graph, PT walk, dist lock, PagedAttention) | done |
| U50 OOC synthesis on Tiara core | done — WNS +0.184 ns @ 200 MHz |
| Tiara → Corundum app-block integration (host AXI-Lite path) | done |
| Tiara → Corundum app-block integration (RX/TX wire datapath) | done |
| End-to-end Verilator app testbench (RX→Tiara→TX) | done — 8/8 cases pass |
| U50 OOC synthesis + impl on integrated app block | done — WNS +0.077 ns @ 200 MHz |
| Full Corundum AU50 bitstream build | scripted |
| Linux character device driver (`tiara_drv`) | source ready |
| Userspace wire client (`tiara_wire.py`) | source ready |
| **Operator MEMCPY → host DRAM via XDMA descriptors** | **done** |
| **Multi-MP wire-path routing through tiara_op_table** | **done** |
| **ANDI+ADD region inheritance in verifier** | **done** |
| **Tiara C compiler frontend (paper §3.4)** | **done** |
| Hardware bring-up on real U50 + ConnectX-5/6 | needs hardware |

## Recently landed

### XDMA descriptor path (paper §3.2 host DMA)

Operator memory ops against device 0 now route through
`tiara_xdma_engine.sv`, which emits Corundum's
`m_axis_data_dma_read_desc_*` / `m_axis_data_dma_write_desc_*`
descriptors and consumes their status streams.  The engine exposes
its scratchpad to Corundum via the `data_dma_ram_*` slave port group,
matching the `mqnic_app_block` interface byte-for-byte.

Verifier-friendly Verilator flow: `tiara_xdma_host_stub.sv` simulates
the Corundum DMA fabric against an in-memory host array with a
fixed-cycle latency model.  `make -C sim/verilator xdma` builds an
end-to-end binary; `sw/tests/xdma_test.py` covers LOAD / STORE / CAS
through the descriptor path.

### Multi-MP wire-path dispatch

`tiara_datapath_top.sv` now embeds `tiara_op_table` (256-entry
op_id→start_pc lookup).  Wire-path invocations carry an `op_id` in
bytes 20..23; the table feeds `inv_start_pc` into the dispatcher so
the same NIC can host many operators registered at different istore
offsets.  See `sim/cosim_app/sim_app.cpp` selftest cases 7-8.

### Verifier ANDI+ADD region inheritance

`AbsVal.add()` and `_check_addr_reg` now correctly propagate region
tags through the canonical `LOAD → ANDI(mask) → ADD(region_base)`
pattern.  Tests in `sw/tests/asm_test.py`:
`test_andi_inherits_region_via_add`,
`test_reject_andi_too_wide_for_region`, `test_reject_unmasked_load`.

### Tiara C compiler

`sw/compiler/tiara_cc.py` implements a restricted-C → Tiara assembly
compiler matching the SCoP subset described in paper §3.4.  Pure
Python (uses `pycparser` for the front-end), a linear-scan register
allocator over r9..r15, and a peephole that recognizes
`tiara_andi(load_result, MASK)` as the canonical region-clamp pattern.
Examples in `sw/compiler/examples/*.c`; integration tests in
`sw/tests/compiler_test.py`.

## Remaining work

### 1. Hardware bring-up on real U50 + ConnectX-5/6

The end-to-end RTL + Linux driver + userspace client are all built
and unit-tested in simulation.  Live silicon validation needs an
actual U50 + ConnectX testbed.  `scripts/build_bitstream.sh` produces
the deployable `hw/build/fpga.bit`; `make program` JTAG-loads it.

### 2. PRISM / RedN comparison hardware microbench

For a fully fair head-to-head, both baselines would need to be
implemented on the same Corundum stack and measured end-to-end.  The
current evaluation uses calibrated analytical models in
`eval/scripts/harness.py`.

## Won't fix here

* **BlueField-2 microbenchmark (paper §2 Fig 2)** — needs a physical
  BF2 NIC. Paper-cited values stand.
* **Live transactions over the wire** — needs U50 + ConnectX
  hardware.
