# FPGA build (Alveo U50)

This document is for actually putting Tiara through Vivado on the
target part `xcu50-fsvh2104-2-e`. Functional correctness lives in
`docs/REPRODUCIBILITY.md` (Verilator); this is the synthesis story.

## What we synthesize

The default `tcl/synth.tcl` synthesizes `tiara_nic_top` in **out-of-context
(OOC) mode**. Scope:

| Component                        | Synthesized? | Notes                                               |
|----------------------------------|--------------|-----------------------------------------------------|
| `tiara_alu`, `tiara_regfile`     | yes          | core compute path; regfile is 3R1W                  |
| `tiara_istore`                   | yes          | inferred BRAM (1024 × 64 bit)                       |
| `tiara_loop_stack`               | yes          |                                                     |
| `tiara_mp`, `tiara_dispatcher`   | yes          |                                                     |
| `tiara_op_table`                 | yes          | 256-entry op_id → start_pc lookup (wire path)       |
| `tiara_mp_array`, `tiara_dispatcher_n` | yes    | 8-MP scaling                                         |
| `tiara_pcie_dma`                 | yes (stub)   | small BRAM stub for OOC; production uses `tiara_xdma_engine` |
| `tiara_xdma_engine`              | yes          | emits Corundum DMA descriptors; consumes `data_dma_ram_*` |
| `tiara_rdma_engine`              | yes (stub)   | small per-peer BRAM — replace with Corundum RDMA in production |

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

Measured utilization on U50 (`xcu50-fsvh2104-2-e`, 200 MHz target,
Vivado 2025.2):

| Configuration                          | LUT     | FF      | BRAM-36 | DSP | WNS         |
|----------------------------------------|--------:|--------:|--------:|----:|------------:|
| 1-MP core (post-route)                 | 27,286  | 84,733  | 2       | 10  | +0.184 ns   |
| Tiara + Corundum app block (post-route)| 28,235  | 86,400  | 2       | 10  | +0.077 ns   |
| 8-MP core (post-synth)                 | 224,465 | 676,765 | 16      | 80  | +1.187 ns   |

The 8-MP build uses ~26% of the U50's LUT budget, ~1% of BRAM, and
~1% of DSP — well within the device. Post-route is expected to
shrink the LUT count further (Vivado's place-and-route routinely
saves 10-25% over post-synth). The integrated app-block adds only
~1 K LUTs over the standalone Tiara core, since Corundum's wrapper
(`mqnic_app_block`) is mostly pass-through wiring on top of the
data path Tiara owns.

## Replacing the BFMs with real IP

The repo ships two memory-subsystem flavors:

1. **`tiara_mem_simple` / `tiara_pcie_dma`** (default OOC) — BRAM-backed
   functional model.  Synthesizes cleanly into a few BRAM tiles, used
   for the post-route timing numbers above.

2. **`tiara_xdma_engine` + `tiara_synth_top_xdma`** (production) —
   emits Corundum-shaped DMA descriptors against the
   `m_axis_data_dma_*` port group + `data_dma_ram_*` slave port group
   of `mqnic_app_block`. To deploy on the real U50:

   a. Build the integrated bitstream with
      `scripts/build_bitstream.sh`, which splices Tiara into Corundum's
      mqnic AU50 fabric, sets `APP_ENABLE=1`, and runs the full Vivado
      flow (Vivado runtime ~45-90 min).
   b. Or hand-instantiate `tiara_xdma_engine` from
      `mqnic_app_block.sv` and connect its `m_axis_dma_*` /
      `dma_ram_*` ports to the matching Corundum slave/master ports.

3. **RDMA engine**: `tiara_rdma_engine.sv` is still a BRAM-backed BFM
   in this repo. Replacing it with Corundum's RDMA pipeline is a
   future-work item (paper §3.2 cross-host MEMCPY).

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
