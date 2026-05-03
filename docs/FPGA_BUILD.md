# FPGA build (Alveo U50)

This document is for actually putting Tiara through Vivado on the
target part `xcu50-fsvh2104-2-e`. Functional correctness lives in
`docs/REPRODUCIBILITY.md` (Verilator); this is the synthesis story.

## What we synthesize

The default `tcl/synth.tcl` synthesizes `tiara_nic_top` in **out-of-context
(OOC) mode**. Scope:

| Component                        | Synthesized? | Notes                                               |
|----------------------------------|--------------|-----------------------------------------------------|
| `tiara_alu`, `tiara_regfile`     | yes          | core compute path                                   |
| `tiara_istore`                   | yes          | inferred BRAM (1024 × 64 bit)                       |
| `tiara_loop_stack`               | yes          |                                                     |
| `tiara_mp`, `tiara_dispatcher`   | yes          |                                                     |
| `tiara_pcie_dma`                 | yes (stub)   | small BRAM stub — replace with Xilinx XDMA in production |
| `tiara_rdma_engine`              | yes (stub)   | small per-peer BRAM — replace with Corundum in production |

Sim-only constructs (`initial` blocks, `export "DPI-C" task`,
multi-cycle blocking copy loops in `always_ff`) are gated with
`` `ifndef SYNTHESIS ``. Vivado defines `SYNTHESIS` automatically;
Verilator does not.

The `MEM_DEPTH` parameters are also gated: simulation uses
4 MiB / 1 MiB BRAM stubs to host realistic test memories; synthesis
collapses to 8 KiB / 2 KiB so the BRAM count reflects the *Tiara
logic*, not the simulator's playground RAM.

## Prereqs

```bash
sudo apt-get install -y libtinfo5 libncurses5    # Vivado runtime
# Vivado ML Standard 2025.2 or newer with U50 device support installed
```

The repo ships:

- `board_files/au50/` — Vivado board file (xilinx.com:au50:part0:1.3)
- `constraints/alveo-u50-xdc.xdc` — Xilinx master XDC for U50QSFP boards
- `constraints/tiara.xdc` — minimal OOC constraints (200 MHz primary clock)
- `tcl/synth.tcl` — out-of-context synthesis
- `tcl/impl.tcl` — opt → place → route, plus reports

## One-command build

```bash
make synth      # ~5–10 min on a 32-core box
make impl       # ~10–30 min depending on congestion
```

Outputs land in `synth/`:

```
synth/tiara.dcp                  post-synth checkpoint
synth/util_post_synth.rpt        synth utilization
synth/timing_post_synth.rpt      synth timing summary
synth/tiara_routed.dcp           post-route checkpoint
synth/util_post_route.rpt        post-route utilization
synth/timing_post_route.rpt      post-route timing summary (WNS / WHS)
synth/methodology_post_route.rpt methodology checks
synth/drc_post_route.rpt         DRC checks
```

## Calibration vs. paper

The paper §4.1 reports **~64 K LUTs, ~78 BRAMs, 200 MHz** for the
Tiara logic on U50 (~8% of the device). The ship-as-default RTL in
this repo synthesizes a **single MP** (the cycle-accurate testbench
configuration), so the expected utilization is:

| Resource      | Paper (8 MPs) | This repo (1 MP, expected) |
|---------------|--------------:|---------------------------:|
| LUT           | ~64 K         | ~6–10 K                    |
| FF            | (not reported)| ~3–5 K                     |
| BRAM (36 Kb)  | ~78           | ~8–14                      |
| Fmax          | 200 MHz       | 200 MHz target             |

Multiply by 8 to estimate the full design. To synthesize the 8-MP
core directly, add a parameterised wrapper around `tiara_mp` —
the `MP_ID` parameter on `tiara_mp` is already there.

## Replacing the BFMs with real IP

For a deployable bitstream:

1. **PCIe DMA**: replace `tiara_pcie_dma.sv` instantiation in
   `tiara_memory_subsystem.sv` with the Xilinx XDMA AXI master IP.
   Generate with Vivado IP Catalog:
   `Vivado → IP Catalog → DMA/Bridge Subsystem for PCI Express → XDMA`.

2. **RDMA engine**: replace `tiara_rdma_engine.sv` with the
   Corundum RDMA pipeline. Clone:
   ```
   git clone https://github.com/corundum/corundum
   cp -r corundum/fpga/mqnic/AU50/fpga_25g/rtl/* path/to/integration/
   ```
   and wire the Tiara request/response interface to Corundum's
   message-level RDMA endpoints.

3. **Top**: build a `tiara_nic_full_top.sv` that places XDMA, Corundum,
   and Tiara on the same clock + AXI interconnect.

## Common issues

* **`SYNTHESIS not defined`**: The synth flow passes
  `-verilog_define SYNTHESIS=1`. If you run synth_design manually,
  set this yourself or sim-only constructs (DPI tasks) will be
  parsed and rejected.
* **`board_part not found`**: Vivado 2025.2 may have a newer U50
  board file revision. Either update the catch'd assignment in
  `tcl/synth.tcl` or remove it — out-of-context synth doesn't
  require a board file.
* **`int s_count [...]` warnings**: Vivado is fine with `int` arrays
  but reports `WIDTHEXPAND` info. Suppress with `-quiet` or
  `set_msg_config -id ...`.
* **WNS < 0 at 200 MHz**: The default OOC constraints are
  pessimistic (no pin placement). In a full Corundum-integrated
  build, the design hits 200 MHz with margin (paper §4.1).
