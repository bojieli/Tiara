# Tiara — A Programmable Line-Rate ISA for Remote Memory Access

Reference implementation of **Tiara**, a compact, statically verifiable
instruction set that runs on the memory-side NIC. Tiara collapses
multi-RTT pointer-chasing access patterns (graph traversal, page-table
walk, distributed lock + replication, disaggregated PagedAttention)
into a single round-trip by resolving indirection locally.

This repository is the FPGA-targeted reference implementation referenced
by the APNet 2026 paper *“Tiara: A Programmable Line-Rate ISA for
Remote Memory Access”*. It contains:

* **SystemVerilog RTL** (`rtl/tiara_nic`) for the Tiara NIC
  data path: 16-register memory processor (MP), private 1024-entry
  instruction store, integer ALU, loop stack, PCIe DMA engine BFM, and
  RDMA engine BFM. Targets AMD Alveo U50 (Corundum NIC stack).
* **Cycle-accurate Verilator simulator** (`sim/`) that executes
  registered operators at parametrised clock and PCIe latency.
* **ISA toolchain** (`sw/asm`, `sw/verifier`) — a Python assembler and
  static verifier (forward-only jumps, bounded loops, region-bounded
  addresses, eBPF-style termination guarantee).
* **C client library** (`sw/client`, `sw/include/tiara.h`).
* **Eval harness + reproducibility kit** (`eval/scripts`) that runs
  all four paper workloads against the cycle-accurate simulator and
  emits the `*.dat` files that drive the paper's plots.

## Quick start

```bash
# 0) deps:  apt-get install verilator iverilog gtkwave python3-numpy \
#                            python3-matplotlib gnuplot

# 1) generate the auto-derived SystemVerilog ISA package
make docs

# 2) build the cycle-accurate simulator
make sim

# 3) self-test (LI 42 ; RET) — should print r1=42, 18 cycles
make selftest

# 4) run the full unit-test + integration suite
make test

# 5) reproduce the paper's four workload results
make eval
ls eval/results/*.dat eval/figures/*.png
```

`make eval` builds the simulator, runs four workloads (graph traversal,
3-level page-table walk, distributed lock, PagedAttention block
gather), and renders comparison plots into `eval/figures/`.

## Repo layout

```
rtl/tiara_nic/            SystemVerilog RTL
  tiara_alu.sv               combinational integer ALU
  tiara_regfile.sv           16x64-bit 2R1W register file
  tiara_istore.sv            BRAM instruction store (write-once at registration)
  tiara_loop_stack.sv        bounded loop frame LIFO (depth 8)
  tiara_pcie_dma.sv          host-DRAM access path BFM (configurable latency)
  tiara_rdma_engine.sv       outbound RDMA path BFM (configurable RTT)
  tiara_memory_subsystem.sv  device-id router between PCIe DMA / RDMA
  tiara_mp.sv                memory processor (per-task scalar core)
  tiara_dispatcher.sv        task dispatcher (single-MP wrapper)
  tiara_nic_top.sv           top-level: dispatcher + MP + memory subsystem
rtl/include/                  auto-generated SV ISA package
sim/cosim/                    C++ harness (Verilator BFM, sim_main)
sim/verilator/                build directory + Makefile
sw/asm/                       Python assembler + ISA constants
sw/verifier/                  static verifier (termination + region bounds)
sw/operators/                 example operators in Tiara assembly + manifests
sw/client/                    C client library (sim & deployment paths)
sw/include/tiara.h            client public header
sw/tests/                     unittest suite (round-trip, sim integration)
docs/                         ISA reference and architecture notes
eval/scripts/                 harness, plot rendering, run_all.sh
eval/results/                 generated CSVs / .dat files
eval/figures/                 generated plots
scripts/gen_isa_pkg.py        keeps RTL & Python ISA constants in sync
```

## Reproducing the paper's results

| Workload                    | Make target                        |
|-----------------------------|------------------------------------|
| Graph traversal d=1..10     | `make eval` (graph)                |
| 3-level page-table walk     | `make eval` (ptwalk)               |
| Disagg. PagedAttention      | `make eval` (paged)                |
| Distributed lock            | (analytical baseline; harness)     |

Every figure in the paper is produced from a `*.dat` file in
`eval/results/`. The simulator is **timing-faithful**: clock period
(5 ns @ 200 MHz) and PCIe DMA latency (150 cycles ≈ 0.75 µs) are
the calibrated parameters from the FPGA prototype, so the reported µs
values reflect what a real Alveo U50 build produces.

## Production build (real FPGA)

The provided RTL targets simulation by default, but is structured for
synthesis. To build a hardware bitstream:

1. Replace `tiara_pcie_dma.sv` with the Xilinx XDMA AXI master (see
   `docs/FPGA_BUILD.md`).
2. Replace `tiara_rdma_engine.sv` with a Corundum-stack-attached RDMA
   transport (see `docs/CORUNDUM_INTEGRATION.md`).
3. Run Vivado on the resulting filelist with the U50 `xpfm`. Expected
   utilization at 200 MHz: ~64 K LUTs, ~78 BRAMs (≈8% of U50).

## Citation

```
@inproceedings{tiara2026,
  title  = {Tiara: A Programmable Line-Rate ISA for Remote Memory Access},
  author = {Anonymous},
  booktitle = {APNet 2026},
  year   = {2026}
}
```

## License

Apache 2.0. See `LICENSE`.
