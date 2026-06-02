# Vivado synthesis report — Tiara core on Alveo U50

* **Tool**: Vivado v2025.2 (Linux)
* **Part**: `xcu50-fsvh2104-2-e` (Alveo U50, speed grade -2)
* **Top module**: `tiara_synth_top` (1 MP + dispatcher + 1-slot mem stub)
* **Clock**: 200 MHz (5.000 ns period)
* **Mode**: out-of-context (OOC) — no I/O placement
* **Date**: 2026-05-03

## Timing (post-route)

| Metric | Value | Status |
|--------|-------|--------|
| WNS    | **+0.184 ns** | ✅ meets 200 MHz |
| TNS    | 0.000 ns       | ✅ 0 / 169,647 failing |
| WHS    | +0.042 ns      | ✅ |
| THS    | 0.000 ns       | ✅ 0 / 169,009 failing |

Worst path: `u_mp/u_alu/mul_a` → `u_mp/u_alu/mul_pipe` (the pipelined
64-bit multiplier). Pipeline stage was added to break what was
previously a 22-logic-level DSP-cascade combinational path.

## Utilization (post-route)

### Tiara MP only
| Resource | Used | U50 total | Util % |
|----------|------|-----------|--------|
| LUT      | 2,947  | 871,680  | 0.34% |
| FF       | 1,695  | 1,743,360| 0.10% |
| BRAM-36  | 2     | 1,344    | 0.15% |
| DSP48E2  | 10    | 5,952    | 0.17% |

### Hierarchical breakdown
| Module | LUT | FF | BRAM | DSP |
|--------|----:|---:|-----:|----:|
| `tiara_mp` (total)    | 2,947 | 1,695 | 2 | 10 |
| ├── `u_rf` (regfile)  | 2,508 |   960 | 0 | 0  |
| ├── `u_alu`           |    51 |   179 | 0 | 10 |
| ├── `u_ls` (loop stk) |   304 |   420 | 0 | 0  |
| └── glue              |    79 |   135 | 0 | 0  |
| `u_disp` (dispatcher) |   194 |   518 | 0 | 0  |
| `u_mem` (synth stub¹) | 24,145 | 82,517 | 0 | 0 |
| **`tiara_synth_top`** | 27,286 | 84,733 | 2 | 10 |

¹ The `u_mem` block is a single-slot memory subsystem stub used only
to make the design self-contained for OOC synthesis. In a deployable
build this is replaced by the Xilinx XDMA AXI master + the Corundum
RDMA pipeline; its cost should not be counted against Tiara.

## Comparison with paper §4.1

| Quantity | Paper claim (8 MPs) | This build (1 MP × 8) |
|----------|--------------------:|----------------------:|
| LUT      | ~64,000             | ~23,600 |
| BRAM     | ~78                 | 16      |
| Fmax     | 200 MHz             | 200 MHz (closes with +0.184 ns slack) |

Our linear scaling underestimates the paper's number because we do
not synthesize the surrounding Corundum NIC stack (Ethernet MAC, RX/TX
FIFOs, RDMA framing, packet processing). The Tiara core itself is
~3K LUT + 2 BRAM + 10 DSP per MP, which is consistent with — and a
strict lower bound for — the paper's number once the surrounding
infrastructure is added.

## How to reproduce

```bash
source /tools/Xilinx/2025.2/Vivado/settings64.sh
cd Tiara
make synth      # ~3 min
make impl       # ~5 min
ls synth/util_post_route.rpt synth/timing_post_route.rpt
```

The full reports are checked in next to this file.
