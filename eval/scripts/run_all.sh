#!/usr/bin/env bash
# Tiara end-to-end reproducibility script.
#
# Builds everything from source, runs all four workloads on the
# Verilator-based simulator, generates result files in eval/results/,
# and renders plots into eval/figures/.
#
# Run this from the repo root:
#     ./eval/scripts/run_all.sh

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "${ROOT}"

echo "=== [1/5] generating SystemVerilog package =================="
python3 scripts/gen_isa_pkg.py

echo "=== [2/5] building Verilator simulator ======================"
make -C sim/verilator

echo "=== [3/5] running self-test ================================="
sim/verilator/build/Vtiara_nic_top --selftest

echo "=== [4/5] running workloads ================================="
mkdir -p eval/results
python3 eval/scripts/harness.py graph  --max-depth 10 --out eval/results/graph_traversal.dat
python3 eval/scripts/harness.py ptwalk                 --out eval/results/pt_walk.dat
python3 eval/scripts/harness.py paged                  --out eval/results/paged_attention.dat \
    --block-sizes 1024 2048 4096 8192 16384 32768 65536 131072 262144

echo "=== [5/5] rendering plots ==================================="
mkdir -p eval/figures
python3 eval/scripts/plots.py

echo "all results in eval/results, plots in eval/figures"
