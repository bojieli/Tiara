# Tiara — A Programmable Line-Rate ISA for Remote Memory Access

Reference implementation of **Tiara**, a compact, statically verifiable
instruction set that runs on the memory-side NIC. Tiara collapses
multi-RTT pointer-chasing access patterns (graph traversal, page-table
walk, distributed lock + replication, disaggregated PagedAttention,
MoE expert paging) into a single round-trip by resolving indirection
locally.

> **First time here?** Read [`docs/TUTORIAL.md`](docs/TUTORIAL.md) — a
> 30-minute walk from zero to running a real operator. Or jump
> straight to [`docs/FAQ.md`](docs/FAQ.md) if something looks weird.
>
> **Prefer to click?** [`web/`](web/) is an interactive companion site
> that runs the whole toolchain (assembler, restricted-C compiler,
> static verifier, single-stepping simulator) in the browser, plus an
> interactive evaluation explorer. `cd web && npm install && npm run dev`.

This repository is the FPGA-targeted reference implementation referenced
by the APNet 2026 paper *“Tiara: A Programmable Line-Rate ISA for
Remote Memory Access”*. It contains:

* **SystemVerilog RTL** (`rtl/tiara_nic`) for the Tiara NIC
  data path: 16-register memory processor (MP), private 1024-entry
  instruction store, integer ALU, loop stack, PCIe DMA engine BFM,
  RDMA engine BFM, **Corundum-shaped XDMA descriptor engine**, and an
  **op_id → start_pc lookup table** for multi-operator wire dispatch.
  Targets AMD Alveo U50 (Corundum NIC stack).
* **Cycle-accurate Verilator simulator** (`sim/`) — two binaries:
  the BRAM-backed model (`Vtiara_nic_top`) and the descriptor-driven
  XDMA flow (`Vtiara_synth_top_xdma`).
* **ISA toolchain** (`sw/asm`, `sw/verifier`) — a Python assembler and
  static verifier (forward-only jumps, bounded loops, region-bounded
  addresses, ANDI+ADD region inheritance, eBPF-style termination
  guarantee).
* **Restricted-C compiler** (`sw/compiler/tiara_cc.py`) — paper §3.4
  SCoP subset of C, lowered through a linear-scan allocator to Tiara
  assembly. Examples in `sw/compiler/examples/`.
* **C client library** (`sw/client`, `sw/include/tiara.h`).
* **Eval harness + reproducibility kit** (`eval/scripts`) that runs
  all five paper workloads against the cycle-accurate simulator and
  emits the `*.dat` files that drive the paper's plots.

## 60-second quickstart

```bash
# 0) deps (Ubuntu 22.04+):
sudo apt-get install -y verilator gtkwave python3-numpy python3-matplotlib \
                        python3-pycparser gnuplot

# 1) build the cycle-accurate simulator (~30s)
make sim

# 2) sanity smoke test  (LI 42 ; RET) → r1=42 in 18 cycles
make selftest

# 3) full Python + sim test suite (29 cases, <1s)
python3 -m pytest sw/tests/

# 4) descriptor-path simulator (Tiara ←→ Corundum-style DMA fabric)
make -C sim/verilator xdma run_xdma

# 5) reproduce the paper's five workloads + plots
make eval
ls eval/results/*.dat eval/figures/*.{png,pdf}

# 6) one-line aggregate report
python3 scripts/make_summary.py && cat reports/SUMMARY.md

# 7) compile a Tiara C operator → assembly → run
python3 sw/compiler/tiara_cc.py sw/compiler/examples/graph_walk.c
PYTHONPATH=sw/asm python3 sw/asm/tiara_asm.py \
    sw/compiler/examples/graph_walk.tasm
```

If any step fails see `docs/REPRODUCIBILITY.md` for environment versions
and `docs/FAQ.md` for common issues.

`make eval` builds the simulator, runs four workloads (graph traversal,
3-level page-table walk, distributed lock, PagedAttention block
gather), and renders comparison plots into `eval/figures/`.

## Repo layout

```
rtl/tiara_nic/            SystemVerilog RTL
  tiara_alu.sv               combinational integer ALU + 2-stage MUL
  tiara_regfile.sv           16x64-bit 3R1W register file
  tiara_istore.sv            BRAM instruction store (write-once at registration)
  tiara_loop_stack.sv        bounded loop frame LIFO (depth 8)
  tiara_pcie_dma.sv          host-DRAM access path BFM (cycle-accurate sim)
  tiara_xdma_engine.sv       Corundum-shaped DMA descriptor engine (production)
  tiara_xdma_host_stub.sv    Verilator-only host-DMA fabric BFM
  tiara_rdma_engine.sv       outbound RDMA path BFM (configurable RTT)
  tiara_memory_subsystem.sv  device-id router between PCIe DMA / RDMA
  tiara_mp.sv                memory processor (per-task scalar core)
  tiara_mp_array.sv          8-MP wrapper with broadcast operator load
  tiara_dispatcher.sv        single-MP task dispatcher
  tiara_dispatcher_n.sv      N-MP first-free arbiter
  tiara_op_table.sv          op_id → start_pc lookup (256 entries)
  tiara_nic_top.sv           top-level: dispatcher + MP + memory subsystem
  tiara_synth_top.sv         single-MP synth target with BRAM stub
  tiara_synth_top_n.sv       8-MP synth target
  tiara_synth_top_xdma.sv    XDMA descriptor flow (Tiara + Corundum DMA fabric)
rtl/include/                  auto-generated SV ISA package
integration/corundum_app/rtl/ Corundum mqnic_app_block + RX filter + TX resp + datapath_top
sim/cosim/                    C++ harness for Vtiara_nic_top + Vtiara_synth_top_xdma
sim/cosim_app/                C++ harness for the wire-path datapath_top
sim/verilator/, verilator_app/ Verilator builds (3 binaries)
sw/asm/                       Python assembler + ISA constants
sw/verifier/                  static verifier (termination + region bounds + ANDI inheritance)
sw/compiler/                  Tiara C compiler (paper §3.4 SCoP subset → assembly)
sw/operators/                 example operators in Tiara assembly + manifests
sw/client/                    C client library (sim & deployment paths)
sw/include/tiara.h            client public header
sw/tests/                     unittest suite (29 cases: assembler, verifier, sim, compiler, XDMA, wire)
docs/                         ISA reference, architecture notes, compiler guide, FAQ
eval/scripts/                 harness, plot rendering, run_all.sh
eval/results/                 generated CSVs / .dat files
eval/figures/                 generated plots (PNG, PDF, EPS)
host/driver/                  Linux character device driver (tiara_drv)
host/client/                  Userspace wire client (tiara_wire.py)
scripts/                      build_bitstream.sh, gen_isa_pkg.py, make_summary.py
tcl/                          Vivado synth/impl scripts
reports/                      synth reports + headline SUMMARY.md
```

## Reproducing the paper's results

| Workload                    | Make target                        |
|-----------------------------|------------------------------------|
| Graph traversal d=1..10     | `make eval` (graph)                |
| 3-level page-table walk     | `make eval` (ptwalk)               |
| Disagg. PagedAttention      | `make eval` (paged)                |
| Distributed lock            | `make eval` (dist_lock)            |
| Crossover (Fig 3)           | `make eval` (crossover)            |

After `make eval`, the headline numbers go to `reports/SUMMARY.md`:

| Result | Tiara | Baseline | Speedup | Paper claim |
|---|---|---|---|---|
| Graph traversal d=10        | 8.78 µs       | 25.0 µs (RDMA)        | **2.85×** | 2.85× |
| Page-table walk             | 3.75 µs       | 10.0 µs (RDMA)        | **2.7×**  | 62% lower (2.7×) |
| Distributed lock 1 client   | 4.34 µs       | 12.5 µs (RDMA)        | **2.88×** | 2.3× at 16 clients |
| PagedAttention 8 KB blocks  | 12.10 GB/s    | 4.35 GB/s (RDMA, batch)| **2.78×** | 2.78× |
| MoE expert gather           | 3.19 µs       | 5.68 µs (RDMA)        | **1.78×** | (paper Table 1, not eval'd in paper) |

| Vivado on U50 (xcu50-fsvh2104-2-e, 200 MHz) | LUT | FF | BRAM | DSP | WNS |
|---|---:|---:|---:|---:|---:|
| 1-MP core (post-route)               | 27,286  | 84,733  | 2  | 10 | +0.184 ns |
| Tiara + Corundum app (post-route)    | 28,235  | 86,400  | 2  | 10 | +0.077 ns |
| 8-MP core (post-synth, paper §4.1)   | 224,465 | 676,765 | 16 | 80 | +1.187 ns |

Every figure in the paper is produced from a `*.dat` file in
`eval/results/`. The simulator is **timing-faithful**: clock period
(5 ns @ 200 MHz) and PCIe DMA latency (150 cycles ≈ 0.75 µs) are
the calibrated parameters from the FPGA prototype, so the reported µs
values reflect what a real Alveo U50 build produces.

## Documentation

| File | Topic |
|---|---|
| [`docs/TUTORIAL.md`](docs/TUTORIAL.md)             | 30-minute walk: write, verify, simulate your first operator |
| [`docs/SYSTEM_OVERVIEW.md`](docs/SYSTEM_OVERVIEW.md) | One-page big picture: what every component does and where it lives |
| [`docs/ISA.md`](docs/ISA.md)                       | Binary contract: opcodes, encoding, semantics |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)     | NIC microarchitecture: MP states, op_table, XDMA engine, verifier rules |
| [`docs/COMPILER.md`](docs/COMPILER.md)             | Tiara C subset, builtins, examples |
| [`docs/ADDING_OPERATORS.md`](docs/ADDING_OPERATORS.md) | How to add a new operator end-to-end |
| [`docs/WIRE_PROTOCOL.md`](docs/WIRE_PROTOCOL.md)   | Custom-Ethertype invocation/response packet formats |
| [`docs/FPGA_BUILD.md`](docs/FPGA_BUILD.md)         | Vivado synth/impl flow, U50 utilization, BFM-to-IP swap |
| [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)         | Bitstream load, kernel modules, ConnectX peer setup |
| [`docs/REPRODUCIBILITY.md`](docs/REPRODUCIBILITY.md) | Versions, expected numbers, troubleshooting |
| [`docs/FAQ.md`](docs/FAQ.md)                       | Common pitfalls and gotchas |
| [`docs/ROADMAP.md`](docs/ROADMAP.md)               | What's done; what's left; what won't be done here |

## Production build (real FPGA)

The repo ships a complete, synthesizable Corundum + Tiara integration
that drops Tiara into the standard mqnic application slot:

* **Wire path**: remote clients send Tiara invocation packets directly
  on Ethernet (custom Ethertype `0x88B5`) — see
  `docs/WIRE_PROTOCOL.md`. The packet hits `tiara_rx_filter` inside
  the NIC, dispatches to a memory processor, and a single response
  packet leaves on the TX path. No host CPU involvement.
* **Host-control path**: software writes operator binaries and pokes
  the invoke register over PIO via `/dev/tiara0`. Same MP services
  both paths.

To build the full bitstream:

```bash
make synth_app          # OOC sanity check on the integrated app block
make impl_app           # post-place+route + reports
make test_app           # Verilator end-to-end RX→Tiara→TX (4 cases)
make bitstream          # full Corundum + Tiara bitstream → hw/build/fpga.bit
```

`docs/FPGA_BUILD.md` covers the OOC flow; `docs/DEPLOYMENT.md` the
full bring-up (bitstream, JTAG/flash, mqnic + tiara_drv kernel modules,
ConnectX-5/6 peer setup).

## Citation

TODO.

## License

Apache 2.0. See `LICENSE`.
