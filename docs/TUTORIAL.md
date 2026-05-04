# Tutorial: Your First Tiara Operator

A 30-minute walkthrough that takes you from zero to running a real
operator on the cycle-accurate simulator. No FPGA hardware required.

## What you need

- Linux (Ubuntu 22.04 tested)
- `verilator` 4.x
- Python 3.10+
- A C compiler (gcc)
- ~5 GB free disk

```bash
sudo apt install -y verilator python3-numpy python3-matplotlib build-essential
git clone https://github.com/bojieli/Tiara
cd Tiara
make sim          # builds the cycle-accurate simulator (~1 min)
make selftest     # confirms the simulator runs (should print "r1=42")
```

If the selftest prints `r1=42  err=0`, you're ready. The whole stack
works.

## What is a Tiara operator?

A Tiara **operator** is a tiny program (typically 10–50 instructions)
that runs *inside the NIC*. It can read/write host DRAM, send RDMA
to peers, do integer arithmetic, branch, and loop. The point: collapse
multi-RTT pointer-chasing patterns into a single round-trip.

Think eBPF, but for memory-side NIC offload, with hardware that
guarantees bounded execution.

## Hello operator

Let's write the simplest possible operator: take an argument, add 100
to it, and return.

Create `sw/operators/my_first.tasm`:

```
  .arg input  r1
  ADDI r1, r1, 100
  RET  r1
```

Three things to know:
- `.arg input r1` — names argument 0 (and binds it to register r1)
- `ADDI rd, rs, imm` — add an immediate
- `RET rN` — finish; r1..r4 are returned to the caller

Assemble it:

```
python3 sw/asm/tiara_asm.py sw/operators/my_first.tasm
```

This produces `sw/operators/my_first.bin` (a tiny binary blob — every
operator is two 64-bit instruction words wide here).

Now write a manifest that tells the static verifier what argument
ranges are legal — `sw/operators/my_first.toml`:

```toml
[operator]
name        = "my_first"
version     = 1
max_dynamic = 16

[[arguments]]
name   = "input"
reg    = 1
bounds = [0, 0xFFFFFFFF]
```

Verify it:

```
python3 sw/verifier/tiara_verifier.py \
    sw/operators/my_first.tasm sw/operators/my_first.toml
```

You should see `[OK] my_first v1 ...`. The verifier proves the
operator terminates in ≤ `max_dynamic` instructions and that every
memory access stays within a declared region.

Run it on the simulator:

```
sim/verilator/build/Vtiara_nic_top \
    --op sw/operators/my_first.bin \
    --args 42,0,0,0,0,0,0,0
```

You should see `r0=000000000000008e` (= 142 decimal). Done — you ran
a Tiara operator end-to-end through cycle-accurate RTL.

## A more interesting one: pointer chasing

Now let's do the thing Tiara is actually for. Suppose we have a
linked list in host DRAM and want to walk N hops to find the end.

```
  .arg start  r1
  .arg depth  r2
  LOOP r2, end
  LOAD r1, [r1 + 8]      // next-pointer at offset 8 of every node
end:
  LOAD r1, [r1 + 0]      // final node's data field
  RET  r1
```

The key trick: `LOAD r1, [r1 + 8]` reads memory at address r1 + 8, and
*writes the result back into r1*. The next `LOAD` then immediately
uses that value as its address. No round-trip to the host between
hops.

`LOOP r2, end` runs the body (just one `LOAD`) `r2` times. After the
loop, `r1` holds the address of the final node, and the post-loop
`LOAD` fetches its data.

This is the pattern from §1 of the paper. With one-sided RDMA,
walking 10 hops costs 10 round-trips. With Tiara, it's one round-trip
plus 10 host-DRAM accesses (10 × 0.75 µs ≈ 7.5 µs) — about 3× faster
in the typical case. We measured this end-to-end on Verilator:
`make eval` produces the comparison plot at `eval/figures/graph_traversal.pdf`.

## Where to read next

* `docs/ISA.md` — full instruction-set reference (every opcode,
  encoding, and field).
* `sw/operators/*.tasm` — the four paper workloads, plus MoE expert
  gather, written by hand.
* `docs/ARCHITECTURE.md` — what the FPGA NIC actually looks like.
* `docs/WIRE_PROTOCOL.md` — how a remote client invokes an operator
  over the network (Ethertype 0x88B5).
* `docs/DEPLOYMENT.md` — bringing the U50 + Corundum + ConnectX
  bitstream up on real hardware.

## Pitfalls

* **`LOAD r1, [r1 + 0]` works but `LOAD r1, [r1 + 0]; LOAD r1, [r1 + 0]`
  doesn't (yet).** Each pair of identical-register LOAD-then-LOAD is
  fine; the issue is the verifier flagging the second LOAD's address
  as opaque. The runtime accepts it; the verifier just warns.

* **`LOOP body_label` syntax.** The label must appear *after* the
  loop body. Forward-only — you can't jump backward.

* **`MEMCPY ASYNC` requires `WAIT 0` later.** Otherwise the operator
  may RET while async transfers are still in flight, and the result
  is undefined.

* **`r0` is hard-wired to zero.** Don't try to use it for arguments
  or results. Arguments live in `r1..r8`; results in `r1..r4`.

* **The verifier wants `max_dynamic` in your manifest.** If your
  operator runs more than `max_dynamic` static steps, registration
  fails. Set it generously; this is just a safety belt against
  pathological loops.
