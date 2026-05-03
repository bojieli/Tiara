# Full U50 bitstream — Tiara + Corundum AU50 25g

* **Tool**: Vivado 2025.2
* **Part**: xcu50-fsvh2104-2-e (Alveo U50)
* **Top**: `fpga` (Corundum AU50 platform with Tiara as the
  application block)
* **Output**: `fpga.bit` (31 MB) — JTAG-loadable / SPI-flashable
* **Build time**: ~40 min (synth + opt + place + phys_opt + route + bitgen)
* **Errors**: 0
* **Warnings**: 0 (during write_bitstream)
* **Build artifacts**: `vendor/corundum/fpga/mqnic/Alveo/fpga_25g/fpga_AU50/fpga.bit`

## Timing (post-route, full design)

| Metric | Value | Notes |
|--------|-------|-------|
| WNS post-route | **-0.153 ns** | 153 ps over budget on Corundum's 250 MHz PCIe Gen3 path; **not** on the 200 MHz Tiara clock domain |
| TNS | -50.671 ns | 934 of 488,653 endpoints failing (0.19%) |
| WHS | +0.006 ns | hold met |

The negative WNS is on Corundum's 250 MHz internal clock (the PCIe AXI
domain), not on the 200 MHz Tiara clock.  The Tiara core itself
closes 200 MHz with **+1.187 ns** slack (verified separately by
`make synth_8mp` and `make impl_app`).

A production deployment would close the remaining 153 ps with one
extra phys_opt pass or by relaxing Corundum's PCIe clock to 200 MHz
(both standard moves).  We left the bitstream as-is to preserve the
honest snapshot.

## Utilization (full design, post-place, on U50)

| Resource          | Used    | U50 total | Util%  |
|-------------------|--------:|----------:|-------:|
| LUT (logic)       |  89,729 |   871,680 | 10.29% |
| LUT (memory)      |   9,437 |   403,200 |  2.34% |
| LUT (total)       |  99,166 |   871,680 | 11.38% |
| FF                | 176,806 | 1,743,360 | 10.14% |
| (CARRY8, MUXes etc shown in full report) | | | |

Of the 99 K LUTs, the Tiara core (incl. RX/TX wire datapath +
AXI-Lite control) is **~28 K LUT** (per the OOC reports in
`reports/u50_2025.2_app_post_route/`).  The remaining ~71 K LUT is
Corundum's mqnic + PCIe + Ethernet pipeline.

Total budget: **~11% of U50 area**, comfortably matching the paper's
claim ("~8% of U50 for Tiara") with the Corundum surrounding
infrastructure on top.

## Files generated

```
fpga.bit                              31 MB  - JTAG-loadable bitstream
fpga.runs/impl_1/fpga_routed.dcp     post-route checkpoint
fpga_utilization_placed.rpt          post-place utilization
fpga_timing_summary_routed.rpt       post-route timing
fpga_drc_routed.rpt                  DRC checks (clean)
fpga_methodology_drc_routed.rpt      methodology checks
```

## How to reproduce

```bash
source /home/ubuntu/Xilinx/2025.2/Vivado/settings64.sh
cd Tiara
make bitstream                       # ~40 min on a 32-core box
ls hw/build/fpga.bit                 # the result
```

## How to deploy

```bash
make program                         # JTAG via U50 management connector
# OR for boot-time loading:
vivado -mode batch -source tcl/flash.tcl   # SPI flash
```

Then load the kernel modules + run the eval harness — see
`docs/DEPLOYMENT.md`.
