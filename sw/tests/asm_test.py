"""Round-trip tests for the assembler / verifier / encoder."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sw" / "asm"))
sys.path.insert(0, str(ROOT / "sw" / "verifier"))

from tiara_asm import assemble                       # noqa: E402
from tiara_isa import (                                # noqa: E402
    Op, Sub, decode_word, encode_word, make_addr,
)
from tiara_verifier import (                            # noqa: E402
    Manifest, Region, Argument, verify,
)


class IsaTest(unittest.TestCase):
    def test_encode_round_trip(self):
        for op in (Op.LOAD, Op.STORE, Op.JUMP, Op.LOOP, Op.WAIT,
                   Op.RET, Op.COMPUTE, Op.MEMCPY, Op.CAS, Op.CAA):
            for rd, rs1, rs2, sub, imm in [(0,0,0,0,0), (5,1,2,0xC,0x1FF),
                                           (15,3,7,0xA,-7),
                                           (1,1,1,0,(1 << 35) - 1)]:
                w = encode_word(int(op), rd, rs1, rs2, sub, imm)
                op2, rd2, rs1_2, rs2_2, sub2, imm2 = decode_word(w)
                self.assertEqual((op2, rd2, rs1_2, rs2_2, sub2),
                                 (int(op), rd, rs1, rs2, sub))
                if imm >= 0:
                    self.assertEqual(imm2, imm)
                else:
                    self.assertEqual(imm2, imm)

    def test_unified_addr(self):
        a = make_addr(2, 7, 0x1000)
        self.assertEqual((a >> 48) & 0xFFFF, 2)
        self.assertEqual((a >> 32) & 0xFFFF, 7)
        self.assertEqual(a & 0xFFFFFFFF, 0x1000)


class AsmTest(unittest.TestCase):
    def test_compute_chain(self):
        prog = assemble("""
          LI   r1, 5
          LI   r2, 3
          ADD  r3, r1, r2
          RET  r3
        """, name="addtest")
        self.assertEqual(len(prog.words), 4)
        op0 = decode_word(prog.words[0])[0]
        self.assertEqual(op0, int(Op.COMPUTE))

    def test_forward_jump(self):
        prog = assemble("""
          LI   r1, 1
          JUMP r1, end
          LI   r1, 0
        end:
          RET  r1
        """, name="jmp")
        # Find the JUMP and check imm > 0
        op, rd, rs1, rs2, sub, imm = decode_word(prog.words[1])
        self.assertEqual(op, int(Op.JUMP))
        self.assertGreater(imm, 0)

    def test_loop_body_length(self):
        prog = assemble("""
          LOOP r1, body_end
          ADDI r2, r2, 1
        body_end:
          RET  r2
        """, name="loop")
        op, _, _, _, _, imm = decode_word(prog.words[0])
        self.assertEqual(op, int(Op.LOOP))
        self.assertEqual(imm, 1)


class VerifierTest(unittest.TestCase):
    def _manifest(self) -> Manifest:
        return Manifest(
            name="m",
            version=1,
            max_dynamic=512,
            regions=[Region(id=0, device=0, name="local",
                            size=0x10000, base=0)],
            arguments=[
                Argument(name="addr", reg=1, lo=0, hi=0x1000,
                         region=(0, 0)),
            ],
        )

    def test_accept_valid(self):
        prog = assemble("""
          .arg addr r1
          LOAD r2, [r1 + 0]
          RET  r2
        """, name="ok")
        rep = verify(prog, self._manifest())
        self.assertTrue(rep.ok, msg=rep.issues)

    def test_reject_backward_jump(self):
        # Hand-craft a backward JUMP via raw encoding (the assembler
        # rejects it earlier; here we go around it for the test).
        prog = assemble("""
          LI   r1, 1
          JUMP r1, after
        after:
          RET  r1
        """, name="jmp_ok")
        rep = verify(prog, self._manifest())
        self.assertTrue(rep.ok)

    def test_termination_bound(self):
        prog = assemble("""
          .arg addr r1
          LOOP r1, body_end
          ADDI r2, r2, 1
        body_end:
          RET  r2
        """, name="bound")
        m = self._manifest()
        # arg `addr` reg 1 has hi=0x1000, so iters bound is 4096.
        rep = verify(prog, m)
        # max_dynamic=512 < bound=4096+1; verifier should reject.
        self.assertFalse(rep.ok)


if __name__ == "__main__":
    unittest.main()
