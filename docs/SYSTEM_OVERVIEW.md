# Tiara — Complete System Overview

This doc is a one-stop tour of every layer in the repo, from the
Tiara ISA up to the deployable U50 + Corundum + ConnectX bitstream.

## Layers

```
            Userspace                                      sw/client/, examples/
            ────────────                                   ─────────────────────
            tiara_wire.py        libtiara.so + tiara.h     example_graph.c
            (raw socket)         (PIO via /dev/tiara0)

            Linux kernel                                   host/
            ────────────────                               ─────
            tiara_drv.ko (mmap of AXI-Lite app region)     mqnic.ko (Corundum)

   ─────────────── PCIe Gen3 + Ethernet ───────────────────────────────

            U50 NIC bitstream                              hw/build/fpga.bit
            ─────────────────                              (built by scripts/build_bitstream.sh)

              mqnic_app_block              ←── Tiara, replaces Corundum's scratch RAM
              ┌──────────────────────────────────┐
              │ tiara_axil_slave  (host PIO)     │
              │ tiara_rx_filter   (wire invoke)  │
              │ tiara_tx_resp     (response pkt) │
              │ tiara_tx_arb      (egress mux)   │
              │ tiara_synth_top   (Tiara core:   │
              │   MP, dispatcher, regfile, ALU,  │
              │   istore, loop stack, mem stub)  │
              └──────────────────────────────────┘
                       (200 MHz, 28K LUT, 2 BRAM, 10 DSP)

              Corundum NIC pipeline (vendor/corundum/fpga/mqnic/Alveo/fpga_25g)
              ┌──────────────────────────────────┐
              │ XDMA, RX/TX queues, DMA engine,  │
              │ Ethernet MAC + GTY transceivers, │
              │ PCIe Gen3 IP, CMS, PTP           │
              └──────────────────────────────────┘
```

## What runs where

| Layer | Source | Verification path |
|-------|--------|---|
| Tiara ISA | `sw/asm/tiara_isa.py` | `python -m unittest sw/tests/asm_test.py` |
| Assembler | `sw/asm/tiara_asm.py` | round-trip + sim test |
| Verifier  | `sw/verifier/tiara_verifier.py` | unit test + manifest validation |
| Tiara core RTL | `rtl/tiara_nic/*.sv` | Verilator: `make selftest` + `make test` (14 cases) |
| Synth-only top | `rtl/tiara_nic/tiara_synth_top.sv` | Vivado OOC: `make synth` (WNS +0.184 ns @ 200 MHz post-route) |
| App-block integration | `integration/corundum_app/rtl/*.sv` + `mqnic_app_block.v` | `make synth_app` + `make impl_app` (WNS +0.077 ns post-route) |
| RX→Tiara→TX datapath | `tiara_rx_filter.sv`, `tiara_tx_resp.sv`, `tiara_tx_arb.sv` | `make test_app` (6 end-to-end cases) |
| Wire protocol | `docs/WIRE_PROTOCOL.md` + `sw/client/tiara_wire.py` | matched against `tiara_packet.svh` and Verilator harness |
| Full bitstream | `scripts/build_bitstream.sh` → Corundum AU50 build | needs Vivado + 45–90 min; produces `hw/build/fpga.bit` |
| Linux driver | `host/tiara_drv.c` | needs U50 hardware to load |
| Userspace | `sw/client/`, `examples/` | C lib + Python wire client |

## Two ways an operator gets invoked

1. **Wire protocol** (data-plane, no host CPU):
   * Client crafts a 96-byte Ethernet frame (Ethertype 0x88B5) with the
     operator ID, task ID, and 8 args.
   * `tiara_rx_filter` snoops Corundum's RX AXIS, classifies on
     Ethertype + magic + op_kind, latches the requester's MAC.
   * Tiara dispatcher forwards to the MP, which executes the operator.
   * `tiara_tx_resp` builds a single 64-byte response packet
     (echoed op_id + task_id + status + r1..r4).
   * `tiara_tx_arb` gives Tiara responses priority on the egress path.

2. **Host control** (programming + debugging):
   * Software opens `/dev/tiara0`, mmaps the AXI-Lite app-control
     region.
   * Operator binary written into the istore via PIO (one 64b
     instruction at a time, two 32b AXI-Lite writes).
   * Args + invoke ctrl bit → tiara_axil_slave → MP.
   * Result polled from status + result registers.

The same MP services both paths, with priority on the wire path.

## Verification matrix

| Layer | Test | Status |
|-------|------|--------|
| ISA encoding | round-trip on every opcode | 5/5 PASS |
| Assembler | label resolution, two-word ops, immediates | 3/3 PASS |
| Verifier | accept/reject paths, termination bound | 3/3 PASS |
| Tiara MP core | LI, ADDI, LOAD, LOAD chain, LOOP, LOAD-in-LOOP | 6/6 PASS |
| RX→Tiara→TX | LI, ADDI, ADD, LOOP, passthrough, back-to-back | 6/6 PASS |
| Vivado synth (Tiara core) | xcu50, OOC, 200 MHz post-route | WNS +0.184 ns ✅ |
| Vivado synth (app block + RX/TX) | xcu50, OOC, 200 MHz post-route | WNS +0.077 ns ✅ |
| Vivado bitstream (full Corundum + Tiara) | scripted; 45–90 min on real Vivado | scripted, in-progress |
| End-to-end on real U50 + ConnectX | needs hardware | not in CI |

## What's verified vs what's claimed

* **Functionally correct**: all 14 + 6 simulation cases pass under
  Verilator. The wire protocol round-trip works in cycle-accurate
  simulation against the actual RTL.
* **Timing**: closes 200 MHz post-place+route on the integrated
  app block (WNS +0.077 ns).
* **Resource cost**: 28 K LUT for the integrated app block (24K is
  the BFM stub, replaced by Corundum DMA in the bitstream); the
  Tiara MP itself is **2,953 LUT + 1,687 FF + 2 BRAM + 10 DSP**.
* **Bitstream**: scripted; not yet observed end-to-end here.
* **Hardware execution on real U50 + ConnectX**: cannot be tested in
  this environment.
