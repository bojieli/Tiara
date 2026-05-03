# Tiara on-the-wire protocol

The Tiara-augmented mqnic exposes operator invocation over the Ethernet
interface using a single custom Ethertype.  This lets remote clients
invoke operators with one round trip — no host CPU on the memory side
sees the request — which is the data-path benefit the paper describes.

## Frame format

* **Ethertype**: `0x88B5` (IEEE Std 802 — Local Experimental).
* **Payload byte order**: little-endian for all multi-byte Tiara fields
  (matches the host's natural integer byte order so userspace doesn't
  byte-swap).  The Ethernet header itself is big-endian per IEEE 802.3.

### Invocation request — 96 bytes

| Bytes | Field      | Notes                                     |
|-------|------------|-------------------------------------------|
| 0..5  | dst MAC    | NIC's MAC                                 |
| 6..11 | src MAC    | requester's MAC (echoed in response)      |
| 12..13| ethertype  | `0x88B5`, big-endian                      |
| 14..17| magic      | `0x010071A5`, little-endian               |
| 18..19| op_kind    | `0x0001` (invoke), little-endian          |
| 20..23| op_id      | registered operator ID                    |
| 24..27| task_id    | client-chosen, echoed in response         |
| 28..31| flags      | reserved, set to 0                        |
| 32..95| args[0..7] | 8 × 8-byte little-endian arg registers    |

The 96-byte payload spans two 64-byte AXIS beats on Corundum's
internal 512-bit interface:
* beat 0 (full): bytes 0..63 — Ethernet hdr + Tiara hdr + args[0..3]
* beat 1 (32 bytes valid, `tlast`): args[4..7]

### Response — 64 bytes (single beat)

| Bytes | Field        | Notes                                            |
|-------|--------------|--------------------------------------------------|
| 0..5  | dst MAC      | original requester (was the invocation src)      |
| 6..11 | src MAC      | NIC's MAC                                        |
| 12..13| ethertype    | `0x88B5`                                         |
| 14..17| magic        | `0x010071A5`                                     |
| 18..19| op_kind      | `0x0002` (response), little-endian               |
| 20..23| op_id        | echoed                                           |
| 24..27| task_id      | echoed                                           |
| 28..29| status       | bit 0 = done, bit 1 = err                        |
| 30..31| reserved     | 0                                                |
| 32..63| result[0..3] | 4 × 8-byte little-endian return values (r1..r4)  |

## Reference client

`sw/client/tiara_wire.py` builds + sends invocations over an
`AF_PACKET` raw socket (requires `CAP_NET_RAW`). Synchronous example:

```bash
sudo python3 sw/client/tiara_wire.py \
    --iface eth1 --dst 00:AA:BB:CC:DD:01 \
    --op 0x42 --task 0x1 --args 7,11
# -> result[0] = 18, ...
```

A C client wrapper around the same protocol is provided through
`sw/client/libtiara.so`. It uses `libpcap` or `AF_PACKET` for
transport and handles operator load (out-of-band, via the AXI-Lite
host control plane on `/dev/tiara0`) followed by data-plane
invocations on the wire.

## In-NIC datapath

```
   Ethernet RX (Corundum)  ──┐
                              │   tiara_rx_filter
                              ▼   (snoop ethertype + magic; pass others through)
                          ┌────────┐                                tiara_synth_top
                          │ filter │ ──── inv_valid + args ──────► (1 MP × 200 MHz)
                          └────────┘                                    │
                                                                        ▼
                                                              tiara_tx_resp
                                                              (build 64-byte resp)
                                                                        │
                                                                        ▼
                                                              tiara_tx_arb
                                                              (priority over host TX)
                                                                        │
                                                                        ▼
                                                              Ethernet TX (Corundum)
```

* Non-Tiara packets pass through `tiara_rx_filter` unchanged — the rest
  of the mqnic stack is unaware.
* `tiara_tx_arb` gives Tiara responses priority on the egress path
  (responses are short and infrequent vs. host data-plane traffic).
* The captured src MAC of the invocation becomes the dst MAC of the
  response, so clients identify themselves naturally on multipoint
  networks.

## Validation

`make test_app` builds and runs the Verilator end-to-end test (RX
synthetic packet → Tiara → TX response) for four operators
(immediate, ADDI, register-register ADD, bounded loop). All four
pass; full pipe latency is ~38–80 cycles depending on the operator.
