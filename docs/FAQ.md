# FAQ

## What does this repo actually do?

Implements **Tiara** — a small, statically verified instruction set
that runs on a memory-side NIC.  Operators register at the NIC, then
remote clients invoke them with a single round-trip.  The NIC walks
multi-level pointer chains, page-table-style indirections, and
distributed coordination locally.

The repo contains:

1. The Tiara core RTL (SystemVerilog, synthesizable for Alveo U50)
2. A cycle-accurate Verilator simulator
3. The ISA toolchain (assembler + verifier)
4. The paper's evaluation harness + plotting code
5. End-to-end integration into Corundum's mqnic AU50 NIC
6. A built U50 bitstream (`make bitstream`)
7. Linux driver + userspace client

## How do I get started?

If you have ~30 minutes, read `docs/TUTORIAL.md`.  Short version:

```bash
sudo apt install -y verilator python3-numpy python3-matplotlib build-essential
make sim selftest test     # build + run all sim tests (~3 min)
make eval                  # reproduce the paper's figures (~5 min)
```

## I don't have a U50 / FPGA.  Is this useful?

Yes.  Everything except `make bitstream` and `make program` runs in
software:

- The **cycle-accurate simulator** runs every operator in
  Verilator-built RTL.  Latency / cycle counts come from the actual
  RTL clock counts, calibrated to match the U50 prototype timings
  reported in the paper.
- The **eval harness** uses the simulator's measured numbers for the
  Tiara line; the comparison baselines (RDMA, RPC, RedN, PRISM) are
  from the analytical model in `eval/scripts/harness.py`.

The four paper workloads + MoE expert gather + crossover figure all
reproduce without hardware.

## What can't I run without hardware?

- The actual end-to-end measurements on a U50 + ConnectX-5/6 testbed.
- The BlueField-2 microbenchmark from paper Fig 2 (needs a BF2 NIC).

`make bitstream` produces `hw/build/fpga.bit` (a real, deployable U50
bitstream) but bringing it up requires the physical board.  See
`docs/DEPLOYMENT.md`.

## Why does my operator's memory access produce a verifier warning?

Per paper §3.3, the verifier wants every memory access to be provably
within a declared region.  Values produced by `LOAD` are *opaque* to
the verifier (they came from memory, the verifier doesn't know what's
there), so a chain like `LOAD r1, [r1+8]; LOAD r1, [r1+0]` triggers
"opaque address; runtime region check required."

The runtime region check still applies (the address is sanity-checked
against the operator's declared regions before each memory access).
The warning is just informational — your operator will run.

To make the warning go away, mask the loaded value with `ANDI` before
using it as an address:

```
LOAD r1, [r1 + 8]
ANDI r1, r1, 0x7FFFFFF8     // clamp into region 0's offset window
LOAD r1, [r1 + 0]
```

The verifier then proves the bound statically.

## Why does Vivado synthesis show 24K LUT for the memory stub?

That's `tiara_mem_simple.sv`, the synthesizable BRAM stub used during
out-of-context synthesis to keep the design self-contained.  In a
production build it's replaced by the Xilinx XDMA AXI master + Corundum
DMA pipeline (which live outside the Tiara budget).  The Tiara
*compute core* is ~3K LUT/MP; multiply by 8 to get ~25K LUT for the
8-MP build.

`make impl_app` reports the integrated app-block utilization
(WNS = +0.077 ns @ 200 MHz post-route) — that's what matters for the
paper's "8% of U50" claim.

## What's the difference between `make synth`, `make synth_app`, and `make synth_8mp`?

| Target | Top module | Purpose |
|---|---|---|
| `make synth` | `tiara_synth_top` (1 MP) | Quick OOC sanity check on the Tiara core |
| `make synth_app` | `mqnic_app_block` (Tiara + RX/TX wire datapath + AXI-Lite host control, 1 MP) | What the actual bitstream's app slot looks like |
| `make synth_8mp` | `tiara_synth_top_n` (8 MPs) | The paper's design point (§4.1); confirms the 8-MP scaling |
| `make bitstream` | the full Corundum AU50 platform with Tiara as the app block | Produces `fpga.bit` |

## I get `Could not get a console!!!` when running xsetup.

Vivado's installer requires a real TTY for `AuthTokenGen` (it prompts
for AMD account credentials).  In Claude Code, prefix the command with
`!` to run it in your interactive shell.  Once the auth token is
generated, the rest of the install runs in batch.

## My operator returns 0 on the simulator

Three usual causes:

1. **The MP took the failure path.**  Check what your operator returns
   on FAIL — many of the paper operators use `0xDEAD` as the failure
   sentinel.  `r0` of the simulator output is *MP register r1*; if
   your `RET r1` ran the FAIL branch, you'll see the FAIL constant.

2. **You're reading register 0.**  The simulator output prints
   `r0=...` but that's the contents of *MP register r1* (the first
   return slot).  Don't confuse `r0` (always-zero) with `r1` (first
   real register).

3. **You forgot a `WAIT 0`.**  Async MEMCPY operations need a
   matching WAIT, otherwise the operator may RET while transfers are
   still in flight and the result is undefined.

## How do I add a new workload to `make eval`?

Three files:

1. `sw/operators/<name>.tasm` — the operator
2. `sw/operators/<name>.toml` — the manifest (regions + arg bounds)
3. `eval/scripts/harness.py` — add a `cmd_<name>(args)` function that
   builds the operator, sets up host DRAM seed words, calls
   `run_sim()`, and emits a `.dat` file.

Then add a `plot_<name>(plt)` function to `eval/scripts/plots.py` and
wire it into `main()`.  See `cmd_moe()` and `plot_moe()` for a recent
example that's ~50 lines total.

## The bitstream build failed.  What now?

Most likely causes:

* **`Invalid APP_ID`** — the Corundum template's elaboration check
  expects `APP_ID = 32'h12340001`.  `scripts/build_bitstream.sh` patches
  `config.tcl` to set this.  If you run the build by hand, set it
  yourself.
* **`part-select [N:M] out of range`** — width-mismatched bit slicing.
  Our RX/TX modules are `DATA_WIDTH`-parameterized; if you swap in a
  different platform they'll need different `BEAT_BYTES`.
* **`Cannot find file containing module: mqnic_app_block`** — your
  patched `Makefile` lost the `app/template/rtl/mqnic_app_block.sv`
  entry.  `scripts/build_bitstream.sh` adds it; if you bypass the
  script, add it manually.

The full Corundum build takes ~40 min on a 16-core box.  Watch
`vendor/corundum/.../fpga.runs/synth_1/runme.log` for live progress.
