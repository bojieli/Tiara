"""End-to-end smoke tests against the Verilator simulator."""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SIM  = ROOT / "sim" / "verilator" / "build" / "Vtiara_nic_top"

sys.path.insert(0, str(ROOT / "sw" / "asm"))
from tiara_asm import assemble  # noqa: E402


@unittest.skipUnless(SIM.exists(),
    "simulator not built — run `make sim` first")
class SimTest(unittest.TestCase):

    def _run(self, src, args, dma_words=None):
        prog = assemble(src, name="t")
        with tempfile.NamedTemporaryFile(
                "wb", suffix=".bin", delete=False) as f:
            f.write(prog.to_bin())
            bin_path = Path(f.name)
        seed = None
        if dma_words is not None:
            with tempfile.NamedTemporaryFile(
                    "w", suffix=".hex", delete=False) as f:
                f.write("\n".join(f"{w:016x}" for w in dma_words) + "\n")
                seed = Path(f.name)
        cmd = [str(SIM), "--op", str(bin_path), "--cycles", "200000",
               "--args", ",".join(str(a) for a in args)]
        if seed:
            cmd += ["--dma", str(seed)]
        out = subprocess.run(cmd, capture_output=True, text=True, check=True)
        bin_path.unlink()
        if seed:
            seed.unlink()
        for line in out.stdout.splitlines():
            if line.startswith("RESULT "):
                parts = dict(p.split("=", 1) for p in line[7:].split())
                return {
                    "cycles":  int(parts["cycles"]),
                    "err":     bool(int(parts["err"])),
                    "regs":    [int(parts[f"r{i}"], 16) for i in range(4)],
                }
        self.fail(f"no RESULT in:\n{out.stdout}\n{out.stderr}")

    def test_immediate(self):
        r = self._run("LI r1, 0x1234\nRET r1", [0]*8)
        self.assertEqual(r["regs"][0], 0x1234)

    def test_addi(self):
        r = self._run("ADDI r1, r1, 100\nRET r1", [42] + [0]*7)
        self.assertEqual(r["regs"][0], 142)

    def test_load(self):
        r = self._run("LOAD r1, [r1 + 0]\nRET r1",
                      [0]+[0]*7,
                      dma_words=[0xCAFEBABE])
        self.assertEqual(r["regs"][0], 0xCAFEBABE)

    def test_load_chain(self):
        # words: [8, 16, 24, 0xCAFE]
        # chain via mem[0]->8 -> mem[8]->16 -> mem[16]->24 -> mem[24]->0xCAFE
        src = """
            ADDI r5, r1, 0
            LOAD r5, [r5 + 0]
            LOAD r5, [r5 + 0]
            LOAD r5, [r5 + 0]
            LOAD r5, [r5 + 0]
            ADDI r1, r5, 0
            RET  r1
        """
        r = self._run(src, [0]+[0]*7, dma_words=[8, 16, 24, 0xCAFE])
        self.assertEqual(r["regs"][0], 0xCAFE)

    def test_loop(self):
        # Sum 1..N using a loop: r2 += 1 N times
        src = """
            LOOP r1, body_end
            ADDI r2, r2, 1
        body_end:
            ADDI r1, r2, 0
            RET  r1
        """
        r = self._run(src, [5] + [0]*7)
        self.assertEqual(r["regs"][0], 5)

    def test_loop_with_load(self):
        # Three-hop pointer chase
        src = """
            ADDI r5, r1, 0
            LOOP r2, body_end
            LOAD r5, [r5 + 0]
        body_end:
            ADDI r1, r5, 0
            RET  r1
        """
        r = self._run(src, [0, 3] + [0]*6, dma_words=[8, 16, 24, 0xCAFE])
        self.assertEqual(r["regs"][0], 24)


if __name__ == "__main__":
    unittest.main()
