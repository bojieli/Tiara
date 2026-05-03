# End-to-end deployment on Alveo U50 + ConnectX-5/6

This document describes how to bring up the full Tiara system: Alveo
U50 running the Tiara-augmented Corundum NIC, with one or more
ConnectX-5/6 NICs serving as RDMA peers.

## Hardware

* **FPGA card**: AMD Alveo U50 (HBM, 100 GbE)
* **Peer NIC(s)**: NVIDIA/Mellanox ConnectX-5 or ConnectX-6 (any
  RDMA-capable RoCEv2 NIC works)
* **Hosts**: x86 servers with PCIe Gen3 x16 (or Gen4 x8) slots; one
  for the U50, ≥1 for peers
* **Network**: 100 GbE QSFP28 between U50 and peer(s) — direct DAC
  cable for two-node, TOR switch otherwise

The paper §4.1 testbed uses two dual-socket Intel Xeon Gold 6326
servers. Any reasonably modern x86 server works.

## Software prereqs

```bash
# On the U50 host:
sudo apt-get install -y verilator iverilog python3-numpy python3-matplotlib \
                        build-essential linux-headers-$(uname -r) \
                        libtinfo5 libncurses5

# Vivado ML Standard 2025.2 with U50 device support.

# Mellanox/NVIDIA OFED for the ConnectX peer:
#   Download MLNX_OFED from https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/
#   Install: ./mlnxofedinstall --without-fw-update --force
```

## Step 1 — build the U50 bitstream

```bash
cd Tiara
make bitstream            # ~45 min on a 16-core box (Vivado synth+place+route)
ls hw/build/fpga.bit      # the programmable bitstream
ls hw/build/fpga.mcs      # for flash programming
```

The build does:

1. Run Tiara's synth-only check first (`make synth`) to confirm the
   core elaborates.
2. Copy `integration/corundum_app/rtl/mqnic_app_block.v` and
   `tiara_axil_slave.sv` over Corundum's app template at
   `vendor/corundum/fpga/mqnic/Alveo/fpga_25g/app/template/rtl/`.
3. Add the Tiara core RTL files to Corundum's filelist.
4. Run Corundum's `make` from `vendor/corundum/fpga/mqnic/Alveo/fpga_25g/fpga_AU50`.
5. Copy the resulting `fpga.bit` / `fpga.mcs` to `hw/build/`.

## Step 2 — program the U50

JTAG (USB cable to the U50 management connector):

```bash
cd hw/build
vivado -mode batch -source /home/ubuntu/Tiara/tcl/program.tcl
```

Or flash for boot-time loading:

```bash
vivado -mode batch -source /home/ubuntu/Tiara/tcl/flash.tcl
sudo reboot       # so the U50 reloads from flash
```

After a JTAG load you must `sudo lspci -vv -s <U50 BDF>` to confirm
the device enumerates with the Corundum vendor/device ID.

## Step 3 — load the mqnic kernel module + Tiara extension

```bash
cd vendor/corundum/modules/mqnic
make
sudo insmod mqnic.ko

# Confirm:
ls /dev/mqnic*               # /dev/mqnic0
sudo dmesg | grep mqnic | tail
```

Tiara's host-side extension lives in `host/tiara_drv.c` (a thin
character-device wrapper that exposes the AXI-Lite app-control region
to userspace via `mmap()`). Build + load:

```bash
cd host
make tiara_drv.ko
sudo insmod tiara_drv.ko
ls /dev/tiara0
```

`/dev/tiara0` is `mmap()`-able and exposes the registers documented in
`integration/corundum_app/rtl/tiara_axil_slave.sv` directly to
userspace.

## Step 4 — set up the ConnectX peer

On the peer host:

```bash
sudo /etc/init.d/openibd restart
ibstat                       # confirm ConnectX-5/6 is up
ifconfig <ib_iface> <ip>/24
```

Tiara sees the peer through standard RoCEv2 RDMA, which Corundum
implements over the 100 GbE link. Peer device ID in Tiara's unified
address space is configured by the host driver via the Corundum
control plane.

## Step 5 — register and invoke a Tiara operator

```bash
cd Tiara
make client                  # builds sw/client/libtiara.so

# Assemble + verify the operator
python3 sw/asm/tiara_asm.py sw/operators/page_table_walk.tasm
python3 sw/verifier/tiara_verifier.py \
    sw/operators/page_table_walk.tasm sw/operators/page_table_walk.toml

# Run the host-side example
gcc examples/example_graph.c -Isw/include -Lsw/client -ltiara \
    -o build/example_graph
build/example_graph /dev/tiara0
```

The example writes the operator binary into the U50's instruction
store via PIO over PCIe, sets up arguments in the argument registers,
asserts the invoke bit, polls the status register until done, and
reads back the result registers. End-to-end latency for a 3-level
page-table walk should be ~3.7 µs (Tiara uncontended) per the
simulator's RTL measurement.

## Step 6 — running the paper workloads on the deployed system

```bash
make eval HARDWARE=1
```

`HARDWARE=1` switches the eval harness from the Verilator simulator
to the real U50 device at `/dev/tiara0`. Each invocation goes over
PCIe to the FPGA; the resulting timings are measured end-to-end.
Compare to the simulated values in `eval/results/*.dat`.

## Limitations of the current host-control integration

The `mqnic_app_block` shipping in this repo wires Tiara into the host
AXI-Lite control region. That gives you:

* Software-programmable operator load + invoke + result readout.
* Fully synthesizable, fits in U50, closes 200 MHz timing.
* End-to-end measurable latency from the host process.

What it does **not** yet have:

* Direct path from incoming RDMA packets to the Tiara dispatcher (so
  remote clients invoking operators currently round-trip through the
  host CPU + Tiara PIO).
* Direct AXI master access from Tiara to host DRAM via XDMA (operator
  Memcpy currently hits the synth-time BFM stub).

Both are wiring exercises against the AXIS interfaces already exposed
by `mqnic_app_block`. The data-path RX hookup is the natural next
deliverable; see `docs/ROADMAP.md`.
