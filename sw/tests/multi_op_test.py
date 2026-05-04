"""Multi-operator dispatch test.

Loads two different operators side-by-side into the istore at offsets
0 and 16, then invokes them one after the other with different
start_pc values to verify the dispatcher's `inv_start_pc` plumbs all
the way down to the MP and selects the correct entry point.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SIM  = ROOT / "sim" / "verilator" / "build" / "Vtiara_nic_top"


def _encode(op, rd, rs1, rs2, sub, imm):
    i40 = imm & ((1 << 40) - 1)
    return (op << 56) | (rd << 52) | (rs1 << 48) | (rs2 << 44) | (sub << 40) | i40


@unittest.skipUnless(SIM.exists(),
    "simulator not built — run `make sim` first")
class MultiOpTest(unittest.TestCase):

    def _make_combined(self, op1_words, op2_words):
        """Place op1 at offset 0 and op2 at offset 0x10 (16) in the
        istore.  Pad between them with NOPs so PC advances cleanly."""
        out = list(op1_words)
        while len(out) < 16:
            out.append(0)   # NOP
        out.extend(op2_words)
        return out

    def _run(self, words, args, start_pc):
        with tempfile.NamedTemporaryFile(
                "wb", suffix=".bin", delete=False) as f:
            for w in words:
                f.write(w.to_bytes(8, "little"))
            bin_path = Path(f.name)
        cmd = [str(SIM), "--op", str(bin_path), "--cycles", "100000",
               "--args", ",".join(str(a) for a in args),
               "--start_pc", str(start_pc)]
        out = subprocess.run(cmd, capture_output=True, text=True, check=True)
        bin_path.unlink()
        for line in out.stdout.splitlines():
            if line.startswith("RESULT "):
                parts = dict(p.split("=", 1) for p in line[7:].split())
                return [int(parts[f"r{i}"], 16) for i in range(4)]
        self.fail(f"no RESULT in:\n{out.stdout}\n{out.stderr}")

    def test_two_operators_at_different_offsets(self):
        # Op A at offset 0:    LI r1, 100;   RET r1   (returns 100)
        op_a = [
            _encode(0x20, 1, 0, 0, 0xC, 100),
            _encode(0x13, 0, 1, 0, 0, 0),
        ]
        # Op B at offset 16:  ADDI r1, r1, 7; RET r1  (returns arg + 7)
        op_b = [
            _encode(0x20, 1, 1, 0, 0x8, 7),
            _encode(0x13, 0, 1, 0, 0, 0),
        ]
        words = self._make_combined(op_a, op_b)

        # Invoke op A (start_pc=0) — expect 100
        regs = self._run(words, [0]*8, start_pc=0)
        self.assertEqual(regs[0], 100, f"op A returned {regs[0]}, expected 100")

        # Invoke op B (start_pc=16) with arg=35 — expect 42
        regs = self._run(words, [35] + [0]*7, start_pc=16)
        self.assertEqual(regs[0], 42, f"op B returned {regs[0]}, expected 42")


if __name__ == "__main__":
    unittest.main()
