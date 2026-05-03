# Tiara + Corundum AU50 app block synthesis

* **Tool**: Vivado 2025.2
* **Part**: xcu50-fsvh2104-2-e
* **Top module**: `mqnic_app_block` (Corundum's application slot, with
  Tiara wired into the AXI-Lite host-control region via
  `tiara_axil_slave`).
* **Mode**: out-of-context, 200 MHz primary clock
* **Clock**: WNS = +1.187 ns, TNS = 0 (zero failing endpoints)

## Hierarchical utilization

| Module | LUT | FF | BRAM | DSP |
|--------|----:|---:|-----:|----:|
| `mqnic_app_block` (top)        | 28,279 | 85,491 | 2 | 10 |
| ├── `u_tiara_axil` (AXI-Lite)  |    327 |    933 | 0 | 0  |
| └── `u_tiara_core` (synth top) | 27,952 | 84,555 | 2 | 10 |
|     ├── `u_disp` (dispatcher)  |    196 |    518 | 0 | 0  |
|     ├── `u_mp` (Tiara MP)      |  2,993 |  1,687 | 2 | 10 |
|     │   ├── `u_rf` (regfile)   |  2,520 |    960 | 0 | 0  |
|     │   ├── `u_alu`            |     51 |    179 | 0 | 10 |
|     │   └── `u_ls` (loop stk)  |    327 |    420 | 0 | 0  |
|     └── `u_mem` (synth stub)   | 24,763 | 82,350 | 0 | 0  |

The `u_mem` block is the synth-time BFM stub — replaced by the
Corundum DMA AXI master in the bitstream build.

## What this proves

- The Corundum app-block port contract is honored exactly.
- Tiara fits in the standard mqnic application slot.
- Host-side AXI-Lite control plane (operator load, invocation, result
  readout) maps cleanly into the Corundum BAR.
- 200 MHz timing closes after place + route on the standalone synth.

## Next step (deployment)

`make bitstream` runs `scripts/build_bitstream.sh` which:
1. Splices our `mqnic_app_block.v` + Tiara RTL into Corundum's
   `Alveo/fpga_25g/app/template/rtl/`.
2. Runs Corundum's standard AU50 build, which produces `fpga.bit`.

Place + route of the full Corundum design takes ~45 min on a
16-core box.
