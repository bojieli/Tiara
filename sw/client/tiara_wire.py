"""
Tiara wire-protocol client (Python, AF_PACKET raw socket).

Builds + sends Tiara invocation packets to the U50 NIC and parses
response packets.  Wire format matches
`integration/corundum_app/rtl/tiara_packet.svh`.

Requires CAP_NET_RAW (root or capability) to open AF_PACKET sockets.

    sudo python3 sw/client/tiara_wire.py --iface eth1 \\
        --dst 00:AA:BB:CC:DD:01 --op 0x42 --args 0,0,0,0,0,0,0,0
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple

ETH_P_TIARA = 0x88B5
TIARA_MAGIC          = 0x010071A5
TIARA_KIND_INVOKE    = 0x0001
TIARA_KIND_RESPONSE  = 0x0002


def _mac_to_bytes(s: str) -> bytes:
    return bytes(int(p, 16) for p in s.split(":"))


def build_invocation(dst_mac: bytes, src_mac: bytes,
                     op_id: int, task_id: int,
                     args: List[int], flags: int = 0) -> bytes:
    if len(args) > 8:
        raise ValueError("up to 8 args")
    args = list(args) + [0] * (8 - len(args))
    body = (
        struct.pack("<I", TIARA_MAGIC) +
        struct.pack("<H", TIARA_KIND_INVOKE) +
        struct.pack("<I", op_id) +
        struct.pack("<I", task_id) +
        struct.pack("<I", flags) +
        b"".join(struct.pack("<Q", a & ((1 << 64) - 1)) for a in args)
    )
    eth_hdr = dst_mac + src_mac + struct.pack("!H", ETH_P_TIARA)
    return eth_hdr + body


@dataclass
class Response:
    src_mac: bytes
    op_id:   int
    task_id: int
    status:  int
    result:  List[int]


def parse_response(pkt: bytes) -> Optional[Response]:
    if len(pkt) < 64:
        return None
    if struct.unpack("!H", pkt[12:14])[0] != ETH_P_TIARA:
        return None
    if struct.unpack("<I", pkt[14:18])[0] != TIARA_MAGIC:
        return None
    if struct.unpack("<H", pkt[18:20])[0] != TIARA_KIND_RESPONSE:
        return None
    op_id, task_id = struct.unpack("<II", pkt[20:28])
    status         = struct.unpack("<H", pkt[28:30])[0]
    result = list(struct.unpack("<QQQQ", pkt[32:64]))
    return Response(src_mac=pkt[6:12], op_id=op_id, task_id=task_id,
                    status=status, result=result)


class TiaraWireClient:
    def __init__(self, iface: str):
        self.iface = iface
        self.sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                                  socket.htons(ETH_P_TIARA))
        self.sock.bind((iface, ETH_P_TIARA))
        self.sock.settimeout(1.0)
        # Get our MAC
        ifr = self.sock.getsockname()
        # Linux returns (iface, proto, pkttype, hatype, addr)
        self.src_mac = bytes(ifr[4]) if len(ifr) >= 5 else b"\x00" * 6

    def invoke(self, dst_mac: bytes, op_id: int, task_id: int,
               args: List[int], timeout: float = 1.0) -> Optional[Response]:
        pkt = build_invocation(dst_mac, self.src_mac, op_id, task_id, args)
        self.sock.send(pkt)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                self.sock.settimeout(max(0.001, deadline - time.monotonic()))
                rx = self.sock.recv(2048)
            except socket.timeout:
                return None
            r = parse_response(rx)
            if r and r.task_id == task_id:
                return r
        return None


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface",   required=True, help="net iface, e.g. eth1")
    ap.add_argument("--dst",     required=True, help="U50 NIC MAC, e.g. 00:AA:BB:CC:DD:01")
    ap.add_argument("--op",      required=True, type=lambda s: int(s, 0))
    ap.add_argument("--task",    type=lambda s: int(s, 0), default=1)
    ap.add_argument("--args",    default="",
                    help="comma-separated decimal/hex 64-bit args")
    args = ap.parse_args(argv)

    arg_list = [int(x, 0) for x in args.args.split(",") if x.strip()] if args.args else []
    cli = TiaraWireClient(args.iface)
    r = cli.invoke(_mac_to_bytes(args.dst), args.op, args.task, arg_list)
    if not r:
        print("TIMEOUT")
        return 1
    print(f"op_id={r.op_id:#x} task_id={r.task_id:#x} status={r.status:#x}")
    for i, v in enumerate(r.result):
        print(f"  result[{i}] = {v:#018x}  ({v})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
