# Roadmap

## Status (current)

| Component | Status |
|---|---|
| Tiara ISA + assembler + verifier | done |
| Tiara core RTL (MP, regfile, ALU, istore, loop stack, dispatcher) | done |
| Cycle-accurate Verilator simulator | done — 14/14 unit tests pass |
| Four paper workloads (graph, PT walk, dist lock, PagedAttention) | done |
| U50 OOC synthesis on Tiara core | done — WNS +0.184 ns @ 200 MHz |
| Tiara → Corundum app-block integration (host AXI-Lite path) | done |
| Tiara → Corundum app-block integration (RX/TX wire datapath) | done |
| End-to-end Verilator app testbench (RX→Tiara→TX) | done — 6/6 cases pass |
| U50 OOC synthesis + impl on integrated app block | done — WNS +0.077 ns @ 200 MHz |
| Full Corundum AU50 bitstream build | scripted, in-progress |
| Linux character device driver (`tiara_drv`) | source ready |
| Userspace wire client (`tiara_wire.py`) | source ready |
| Hardware bring-up on real U50 + ConnectX-5/6 | needs hardware |

## Next steps (in priority order)

### 1. Bitstream production

`scripts/build_bitstream.sh` drives the full Corundum AU50 build with
the Tiara app-block spliced in. Vivado runtime ~45–90 min. The end
artifact is `hw/build/fpga.bit` ready to JTAG-load with
`make program`. Validation requires a real U50 board (not currently
available in CI).

### 2. Operator MEMCPY → host DRAM via XDMA

Today the operator's MEMCPY hits the synthesizable BRAM stub
(`tiara_mem_simple`). For real disaggregated-memory workloads we need
to wire the memory subsystem through Corundum's PCIe DMA descriptor
interface to host DRAM:

* **MEMCPY-in-AXI-master form**: replace the BRAM in
  `tiara_mem_simple.sv` with an AXI master that emits
  `m_axis_data_dma_*` descriptors. Corundum's PCIe stack already
  routes those to the XDMA, which performs the DMA against a
  registered host buffer.
* **Hugepage backing**: client library allocates the registered
  buffer via the standard mqnic IOCTLs (already supported by
  `vendor/corundum/modules/mqnic`).

Rough effort: 1–2 days of careful AXIS integration plus a short
Verilator BFM for the DMA descriptor protocol so we can keep the
existing 14 unit tests green.

### 3. Multi-MP scaling (8 MPs as in paper §4.1)

Currently the synth target instantiates one MP. To match the paper's
8-MP build:

* Add `genvar`-based replication of `tiara_mp` instances inside a
  new `tiara_mp_array.sv`.
* Extend `tiara_dispatcher` with a free-MP arbiter (round-robin or
  priority + busy mask).
* Re-run synth: expected utilization ~24K LUT + 16 BRAM
  (single MP × 8) — well below the U50 budget.

### 4. PRISM / RedN comparison hardware microbench

For a fully fair comparison against the paper's RedN and PRISM
baselines, those would need to be implemented on the same
Corundum-style stack and measured end-to-end. The current evaluation
uses the calibrated analytical models from `eval/scripts/harness.py`.

### 5. Static verifier hardening

The current verifier accepts opaque values from `LOAD` with a
warning. A tighter analysis would require operators to insert an
explicit `ANDI` to mask loaded values into a region's offset width
before they can be used as addresses. The verifier already understands
this idiom; making it mandatory is one additional rule.

### 6. Compiler frontend (paper §3.4)

The paper describes operators written in restricted OpenCL C compiled
through an LLVM-based toolchain. Currently operators are written
directly in Tiara assembly (`sw/operators/*.tasm`). An LLVM backend
that lowers the SCoP subset of OpenCL C to Tiara IR is the natural
extension.

## Won't fix here

* **BlueField-2 microbenchmark (paper §2 Fig 2)** — needs a physical
  BF2 NIC. Paper-cited values stand.
* **End-to-end on real U50 + ConnectX-5/6** — needs the hardware
  testbed. Build flow + driver + client are scripted; we cannot
  bring up live transactions without the board.
