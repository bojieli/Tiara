# Tiara + Corundum app block (with RX/TX datapath) post-route

* **Tool**: Vivado 2025.2 (xcu50-fsvh2104-2-e)
* **Top module**: `mqnic_app_block` (Corundum's app slot, with Tiara
  datapath: RX filter → MP → TX response).
* **Mode**: out-of-context, 200 MHz primary clock
* **Date**: 2026-05-03

## Timing (post-route)

| Metric | Value |
|--------|-------|
| WNS    | **+0.077 ns** (closes 200 MHz with margin) |
| TNS    | 0.000 ns (0 / 171,700 failing endpoints) |
| WHS    | +0.044 ns |
| THS    | 0.000 ns |

Adding the full RX/TX wire-protocol datapath consumed ~1.1 ns of
positive slack vs the host-control-only build (was +1.187 ns) — most
of the new logic is in the AXIS arbitration mux.

## Hierarchical utilization (post-route)

| Module | LUT | FF | BRAM | DSP |
|--------|----:|---:|-----:|----:|
| `mqnic_app_block` (top)        | (top sums below) | | | |
| ├── `u_tiara_axil`             | (host PIO path) | | | |
| ├── `u_tiara_rx` (RX filter)   |   290 |   635 | 0 | 0  |
| ├── `u_tiara_tx` (TX resp)     |     1 |   117 | 0 | 0  |
| ├── `u_tiara_tx_arb`           |   381 |     6 | 0 | 0  |
| └── `u_tiara_core`             | 27,291| 84,707| 2 | 10 |
|     ├── `u_disp` (dispatcher)  |   196 |   518 | 0 | 0  |
|     ├── `u_mp`                 | 2,953 | 1,687 | 2 | 10 |
|     │   ├── `u_rf` (regfile)   | 2,506 |   960 | 0 | 0  |
|     │   ├── `u_alu`            |    51 |   179 | 0 | 10 |
|     │   └── `u_ls` (loop stk)  |   304 |   420 | 0 | 0  |
|     └── `u_mem` (synth stub)   |24,142 |82,502 | 0 | 0  |

Wire-protocol RX/TX datapath: **~672 LUT + 758 FF total** — small
fraction of the Tiara MP itself. The 24K LUT BFM stub remains for
out-of-context synthesis self-containment; in the bitstream build it
is replaced by Corundum's PCIe DMA descriptor interface.

## Functional verification (Verilator)

`make test_app` runs 6 end-to-end RX→Tiara→TX cases (LI, ADDI, ADD,
LOOP, passthrough non-Tiara, back-to-back x3) — all pass.
