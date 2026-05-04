"""XDMA descriptor-path smoke test.

Exercises tiara_xdma_engine + tiara_xdma_host_stub through hand-encoded
operators that drive LOAD / STORE / CAS via Corundum-shaped DMA
descriptors instead of the in-RTL BRAM stub.  Builds the dedicated
Vtiara_synth_top_xdma binary on first run via `make xdma`.
"""

import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SIM_DIR = ROOT / "sim" / "verilator"
BIN     = SIM_DIR / "build_xdma" / "Vtiara_synth_top_xdma"


@unittest.skipUnless(BIN.exists(),
    "XDMA simulator not built — run `make -C sim/verilator xdma`")
class XdmaTest(unittest.TestCase):
    def test_descriptor_path(self):
        out = subprocess.run(
            [str(BIN)], capture_output=True, text=True, timeout=120)
        self.assertEqual(out.returncode, 0, msg=out.stdout + out.stderr)
        text = out.stdout
        self.assertIn("xdma:smoke", text)
        self.assertIn("xdma:load",  text)
        self.assertIn("xdma:store", text)
        self.assertIn("xdma:cas",   text)
        self.assertIn("PASS",       text)
        for line in text.splitlines():
            if line.startswith("xdma:") and "err=0" not in line:
                self.fail(f"non-zero err in: {line}")


if __name__ == "__main__":
    unittest.main()
