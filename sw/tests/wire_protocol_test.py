"""Round-trip tests for the on-the-wire packet format (Python ↔ RTL).

Verifies that `sw/client/tiara_wire.py`'s packet builder/parser produces
byte sequences that match what the Verilator app testbench expects.
This guards against drift between the host client and the in-NIC
parser (`tiara_rx_filter`).
"""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sw" / "client"))

from tiara_wire import (              # noqa: E402
    build_invocation, parse_response,
    ETH_P_TIARA, TIARA_MAGIC, TIARA_KIND_INVOKE, TIARA_KIND_RESPONSE,
)


class WireFormatTest(unittest.TestCase):

    def test_invocation_size(self):
        pkt = build_invocation(b"\x00" * 6, b"\x11" * 6,
                               op_id=0x42, task_id=0xCAFE,
                               args=[1, 2, 3, 4, 5, 6, 7, 8])
        self.assertEqual(len(pkt), 96)

    def test_invocation_bytes(self):
        dst = bytes.fromhex("AABBCCDDEE01")
        src = bytes.fromhex("112233445566")
        pkt = build_invocation(dst, src, op_id=0x42, task_id=0xCAFE,
                               args=[0]*8)
        # Ethernet header
        self.assertEqual(pkt[0:6], dst)
        self.assertEqual(pkt[6:12], src)
        # Ethertype is big-endian 0x88B5
        self.assertEqual(pkt[12:14], b"\x88\xB5")
        # Magic is little-endian 0x010071A5: bytes 14..17 = 0xA5,0x71,0x00,0x01
        self.assertEqual(pkt[14:18], b"\xA5\x71\x00\x01")
        # op_kind little-endian 0x0001: bytes 18..19 = 0x01,0x00
        self.assertEqual(pkt[18:20], b"\x01\x00")
        # op_id little-endian 0x42
        self.assertEqual(pkt[20:24], b"\x42\x00\x00\x00")
        # task_id little-endian 0xCAFE
        self.assertEqual(pkt[24:28], b"\xFE\xCA\x00\x00")
        # flags zero
        self.assertEqual(pkt[28:32], b"\x00\x00\x00\x00")
        # Args zero-extended to 64 bytes
        self.assertEqual(pkt[32:96], b"\x00" * 64)

    def test_args_packing(self):
        pkt = build_invocation(b"\x00"*6, b"\x11"*6, 0x42, 0x1, args=[
            0x0102030405060708,
            0x1112131415161718,
        ])
        # First arg occupies bytes 32..39 little-endian
        self.assertEqual(pkt[32:40], bytes.fromhex("0807060504030201"))
        # Second arg
        self.assertEqual(pkt[40:48], bytes.fromhex("1817161514131211"))
        # Remaining args zero
        self.assertEqual(pkt[48:96], b"\x00" * 48)

    def test_response_parse(self):
        # Build a synthetic response packet matching the spec.
        nic_mac    = bytes.fromhex("AABBCCDDEE01")
        client_mac = bytes.fromhex("112233445566")
        from struct import pack
        body = (
            pack("<I", TIARA_MAGIC)
            + pack("<H", TIARA_KIND_RESPONSE)
            + pack("<I", 0x42)
            + pack("<I", 0xCAFE)
            + pack("<H", 0x0001)         # status: bit0=done
            + pack("<H", 0)              # reserved
            + pack("<Q", 42)
            + pack("<Q", 0)
            + pack("<Q", 0)
            + pack("<Q", 0)
        )
        eth = client_mac + nic_mac + pack("!H", ETH_P_TIARA)
        pkt = eth + body
        self.assertEqual(len(pkt), 64)
        r = parse_response(pkt)
        self.assertIsNotNone(r)
        self.assertEqual(r.op_id, 0x42)
        self.assertEqual(r.task_id, 0xCAFE)
        self.assertEqual(r.status, 1)
        self.assertEqual(r.result[0], 42)
        self.assertEqual(r.src_mac, nic_mac)

    def test_response_rejects_wrong_ethertype(self):
        from struct import pack
        bogus = b"\x00"*12 + pack("!H", 0x0800) + b"\x00" * 50
        self.assertIsNone(parse_response(bogus))

    def test_response_rejects_wrong_magic(self):
        from struct import pack
        bogus = (b"\x00"*12 + pack("!H", ETH_P_TIARA) +
                 pack("<I", 0xDEADBEEF) + b"\x00" * 46)
        self.assertIsNone(parse_response(bogus))


if __name__ == "__main__":
    unittest.main()
