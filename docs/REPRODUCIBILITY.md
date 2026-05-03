# Reproducibility Guide

This kit reproduces the four workload measurements from the paper on
any Linux box with `verilator >= 4.0`, gcc, Python 3.10+, and ~50 MB
of free disk.

## Software prerequisites

```bash
sudo apt-get install -y verilator iverilog gtkwave python3-numpy \
                        python3-matplotlib gnuplot build-essential
```

(Verilator 4.038 from the Ubuntu 22.04 repos is sufficient. Newer
Verilators work too, but the testbench has been tested against 4.038
and 5.x.)

## One-command reproduction

```bash
git clone https://github.com/bojieli/Tiara
cd Tiara
make eval                 # ~2 minutes on a modern laptop
```

This produces:

* `eval/results/graph_traversal.dat`   — Tiara vs. RDMA/RPC/RedN/PRISM, depth 1..10
* `eval/results/pt_walk.dat`           — 3-level page-table walk latency
* `eval/results/paged_attention.dat`   — throughput vs. block size
* `eval/figures/*.png`                 — rendered comparison plots

## Step-by-step

```bash
# Regenerate the auto-generated SystemVerilog ISA package
make docs

# Build the cycle-accurate simulator
make sim                  # writes sim/verilator/build/Vtiara_nic_top

# Run the operator self-test
make selftest

# Run the full unittest suite (assembler, verifier, end-to-end RTL)
make test

# Run individual workloads
python3 eval/scripts/harness.py graph  --max-depth 10
python3 eval/scripts/harness.py ptwalk
python3 eval/scripts/harness.py paged --block-sizes 4096 8192 65536
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
parameters):

| Workload                | Tiara (RTL) | RDMA (analytical) | Ratio |
|-------------------------|-------------|-------------------|-------|
| Graph d=1               | 1.66 µs     | 2.50 µs           | 1.5×  |
| Graph d=10              | 8.63 µs     | 25.0 µs           | 2.9×  |
| 3-level PT walk         | 3.70 µs     | 10.0 µs           | 2.7×  |
| PagedAttention 8 KB     | 320 µs      | (varies)          |       |

The ratios match the paper's claims (2.5× at depth 10; 52% lower
latency for page-table walk).

## Troubleshooting

* **Verilator < 4.000.** Some of the SystemVerilog idioms used in
  `tiara_pcie_dma.sv` need `--Wno-fatal --Wno-MULTIDRIVEN`. The
  shipped Makefile already passes them.
* **`Vtiara_nic_top: command not found`.** Run `make sim` first.
* **`unittest` says "simulator not built".** Same — `make sim` first.
* **DPI scope warning.** `Verilator: DPI C Function ... missing
  'context' keyword` is benign; it does not affect correctness.
