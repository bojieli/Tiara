# Timing-closure experiment: Tiara core at 322.265625 MHz

**Question.** The Alveo U50 + Corundum 100 GbE datapath runs at the native
`CLK_1588` clock of **322.265625 MHz** (period 3.103 ns). The paper's
operating point is a conservative **200 MHz**. Does the Tiara core
actually close timing at the faster native datapath clock?

**Answer: no — not in its current form. Measured core Fmax ≈ 250 MHz.**
Reaching 322 MHz would require pipelining the instruction-decode stage,
an RTL change that alters the cycle-accurate latency calibration, so it
is out of scope for the camera-ready. The paper keeps the proven 200 MHz
operating point and makes no 322 MHz claim.

## Flow

* `tcl/synth_322.tcl` — single MP, free out-of-context, clk = 3.103 ns.
* `tcl/synth_322_fp.tcl` — identical RTL, confined to a compact
  2-clock-region-column pblock (`CLOCKREGION_X2Y0:X3Y3`) so the router
  cannot sprawl, isolating the core's logic-limited Fmax.

Part `xcu50-fsvh2104-2-e`, Vivado 2025.2, post-place-and-route.

## Results (post-route, setup WNS at period 3.103 ns)

| Build | Overall WNS (incl. OOC mem stub) | Core-only WNS (`u_mp`+`u_disp`) | Core Fmax |
|---|---:|---:|---:|
| Free OOC (`synth_322`)        | −1.084 ns | −1.051 ns | ~241 MHz |
| Floorplanned (`synth_322_fp`) | −1.009 ns | **−0.857 ns** | **~253 MHz** |

The floorplan recovered ~0.2 ns by removing placement sprawl, confirming
the free-OOC failure was largely routing, not logic. But the core still
misses 322 MHz by ~0.86 ns.

## Why it misses

The core's worst path is **instruction-decode → loop-stack remaining
counter** (`u_mp/iw0_reg` → `u_mp/u_ls/sRemain_reg`): 10 LUT levels,
~1.0 ns logic + ~3.0 ns route at the compact placement. A second
near-critical path is decode → register-file writeback. Both are the
single-cycle decode/execute step that, by design, makes register-chained
loads correct without a pipeline bubble (see `docs/ARCHITECTURE.md`).
Adding a decode pipeline stage would break that single-cycle property
and change every measured latency, so we do not do it here.

## What this does support (paper §2.3, §4.1)

* The Tiara **core** is only **2.95 K LUT + 1.69 K FF + 2 BRAM + 10 DSP**
  per MP and closes **200 MHz** post-route with **WNS +0.184 ns**
  (`reports/u50_2025.2_post_route/`). That tiny, replicable core — eight
  of them in ~3% of a ConnectX-class die — is the load-bearing evidence
  for the "minimal-ISA / hardware co-design" argument, independent of the
  322 MHz question.
* The ~27 K-LUT single-MP synth build is dominated by the out-of-context
  memory stub (`tiara_mem_simple`), replaced by the Corundum DMA pipeline
  in a real bitstream; it should not be counted against the Tiara core.

## Reproduce

```bash
source /path/to/Vivado/2025.2/settings64.sh
vivado -mode batch -source tcl/synth_322.tcl      # free OOC
vivado -mode batch -source tcl/synth_322_fp.tcl   # compact floorplan
grep -A6 "Slack (VIOLATED)" synth_322_fp/timing_core_only_322_fp.rpt | head
```

## Clean closing Fmax (no pipelining, standard flow)

Rather than pipeline the decode stage, we also measured the highest clock
at which the **standard single-MP build closes with zero negative slack**
(`tcl/fmax.tcl`, same flow as `synth.tcl`+`impl.tcl`, no pblock):

| Clock | Setup WNS | Hold WHS | Failing endpoints | Verdict |
|---|---:|---:|---:|---|
| **230 MHz** | **+0.050 ns** | +0.039 ns | **0 / 0** | **CLEAN — fully loadable** |
| 240 MHz | −0.285 ns | +0.047 ns | 5656 / 0 | fails |

So **230 MHz is the clean, fully-synthesizable Fmax** of the design as
built (Tiara core + OOC memory stub), with no RTL pipelining. The
prototype runs at 200 MHz (WNS +0.184 ns) to match the Corundum app
clock. Reports: `fmax_230.0/timing_summary.rpt`, `fmax_240.0/...`.

Reproduce: `TIARA_PERIOD=4.348 vivado -mode batch -source tcl/fmax.tcl`.
