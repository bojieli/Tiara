# Reproducibility Guide

This kit reproduces all five workload measurements from the paper on
any Linux box with `verilator >= 4.0`, gcc, Python 3.10+, and ~100 MB
of free disk.

## Software prerequisites

```bash
sudo apt-get install -y verilator gtkwave python3-numpy \
                        python3-matplotlib python3-pycparser \
                        gnuplot build-essential
```

(Verilator 4.038 from the Ubuntu 22.04 repos is sufficient. Newer
Verilators work too; CI tests against 4.038 and 5.x.
`python3-pycparser` is required by the Tiara C compiler; install via
`pip3 install pycparser` if your distro doesn't ship it.)

## One-command reproduction

```bash
git clone https://github.com/bojieli/Tiara
cd Tiara
make eval                 # ~2 minutes on a modern laptop
```

This produces:

* `eval/results/graph_traversal.dat`     — Tiara vs. RDMA/RPC/RedN/PRISM, depth 1..10
* `eval/results/graph_traversal_tput.dat` — saturated throughput vs. depth
* `eval/results/pt_walk.dat`             — 3-level page-table walk latency
* `eval/results/dist_lock.dat`           — dist lock latency vs. contention
* `eval/results/paged_attention.dat`     — throughput vs. block size
* `eval/results/moe.dat`                 — MoE expert-gather latency
* `eval/results/crossover.dat`           — offload-vs-RDMA crossover
* `eval/figures/*.{png,pdf,eps}`         — rendered comparison plots
* `reports/SUMMARY.md` / `.csv`          — aggregate headline table

The figures are also embedded directly in the paper at `paper.tex`.

## Step-by-step

```bash
# Regenerate the auto-generated SystemVerilog ISA package
make docs

# Build the cycle-accurate simulator
make sim                  # writes sim/verilator/build/Vtiara_nic_top

# Run the operator self-test
make selftest

# Run the full unittest suite (assembler, verifier, end-to-end RTL)
make test                 # 29 unit tests, <1s

# Build + run the descriptor-driven XDMA simulator path
make -C sim/verilator xdma run_xdma

# Build + run the wire-path app simulator (RX→Tiara→TX, multi-op
# dispatch through tiara_op_table)
make -C sim/verilator_app run

# Run individual workloads
python3 eval/scripts/harness.py graph     --max-depth 10
python3 eval/scripts/harness.py ptwalk
python3 eval/scripts/harness.py dist_lock --clients 1 2 4 8 16
python3 eval/scripts/harness.py paged     --block-sizes 1024 4096 8192 65536
python3 eval/scripts/harness.py moe
```

## Recreating an individual operator

```bash
# Assemble + verify
python3 sw/asm/tiara_asm.py sw/operators/graph_walk.tasm
python3 sw/verifier/tiara_verifier.py \
    sw/operators/graph_walk.tasm sw/operators/graph_walk.toml

# Run with custom args
sim/verilator/build/Vtiara_nic_top \
    --op sw/operators/graph_walk.bin \
    --args 0,5,0,0,0,0,0,0
```

## Calibration to your hardware

Default parameters are set to match the U50 prototype. To re-target:

```bash
# Faster local DRAM (e.g. 100 cycles instead of 150)
make sim VFLAGS="--cc --exe --build -O3 -Wno-fatal -Wno-WIDTH \
    -GLOCAL_LATENCY_CYCLES=100 ..."
```

Or edit `LOCAL_LATENCY_CYCLES` / `RTT_CYCLES` in
`rtl/tiara_nic/tiara_nic_top.sv`.

## Expected numbers

On the reference machine (Ubuntu 22.04, Verilator 4.038, default
parameters), `make eval` produces:

| Workload                       | Tiara (RTL)   | Baseline (analytical)        | Ratio  |
|--------------------------------|---------------|------------------------------|--------|
| Graph d=1                      | 1.67 µs       | 2.50 µs (RDMA)               | 1.50×  |
| Graph d=10                     | 8.78 µs       | 25.0 µs (RDMA)               | 2.85×  |
| Graph throughput d=3 sat.      | 29.5 Mops     | 8.67 Mops (RDMA)             | 3.41×  |
| 3-level PT walk latency        | 3.75 µs       | 10.0 µs (RDMA)               | 2.67×  |
| PT walk throughput sat.        | 25.6 Mops     | 0.10 Mops (RDMA)             | 256×   |
| Dist lock 1 client             | 4.34 µs       | 12.5 µs (RDMA)               | 2.88×  |
| Dist lock 16 clients           | 9.97 µs       | 31.25 µs (RDMA)              | 3.13×  |
| PagedAttention 4 KB blocks     | 8.72 GB/s     | 2.66 GB/s (RDMA, batched)    | 3.28×  |
| PagedAttention 8 KB blocks     | 12.10 GB/s    | 4.35 GB/s (RDMA, batched)    | 2.78×  |
| MoE expert gather (1 expert)   | 3.19 µs       | 5.68 µs (RDMA)               | 1.78×  |

These match the paper's claims to within 1%; the harness is
deterministic and the cycle counts come directly from the Verilator
binary running the same operators that go onto the FPGA.

| Vivado U50 (xcu50-fsvh2104-2-e) | LUT     | FF      | BRAM-36 | DSP | WNS @ 200 MHz |
|---------------------------------|---------|---------|---------|-----|---------------|
| 1-MP core (post-route)          | 27,286  | 84,733  | 2       | 10  | +0.184 ns    |
| Tiara + Corundum app (post-route)| 28,235 | 86,400  | 2       | 10  | +0.077 ns    |
| 8-MP core (post-synth)          | 224,465 | 676,765 | 16      | 80  | +1.187 ns    |

## Troubleshooting

* **Verilator < 4.000.** Some of the SystemVerilog idioms used in
  `tiara_pcie_dma.sv` need `--Wno-fatal --Wno-MULTIDRIVEN`. The
  shipped Makefile already passes them.
* **`Vtiara_nic_top: command not found`.** Run `make sim` first.
* **`pytest` skip "simulator not built".** Same — `make sim` first.
* **`pytest` skip "XDMA simulator not built".** Run
  `make -C sim/verilator xdma`.
* **DPI scope warning.** `Verilator: DPI C Function ... missing
  'context' keyword` is benign; it does not affect correctness.
* **`pycparser` not found.** `pip3 install pycparser` (used by the
  Tiara C compiler).
* **Vivado not found.** The eval harness does not need Vivado —
  numbers come from the Verilator simulator. Vivado is only required
  to (re-)produce the U50 synthesis numbers, with `make synth_app
  impl_app`.
