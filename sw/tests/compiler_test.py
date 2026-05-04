"""Tiara C compiler integration test.

Compiles each `sw/compiler/examples/*.c` source through tiara_cc to
Tiara assembly, assembles it, and (when the simulator is built) runs
it on a representative input to confirm the emitted code is
functionally correct.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sw" / "asm"))
sys.path.insert(0, str(ROOT / "sw" / "compiler"))

from tiara_asm import assemble                # noqa: E402
from tiara_cc  import Compiler, CompileError  # noqa: E402

SIM = ROOT / "sim" / "verilator" / "build" / "Vtiara_nic_top"


class CompilerTest(unittest.TestCase):
    def _compile(self, src: Path) -> str:
        return Compiler().compile_file(src)

    def test_graph_walk_compiles_and_assembles(self):
        tasm = self._compile(ROOT / "sw/compiler/examples/graph_walk.c")
        prog = assemble(tasm, name="graph_walk_c")
        self.assertGreater(len(prog.words), 0)
        self.assertIn("graph_pool", prog.regions)
        # Sanity: the assembler kept ANDI as the verifier mandates.
        self.assertIn("ANDI", tasm)
        self.assertIn("LOAD", tasm)
        self.assertIn("LOOP", tasm)

    def test_atomic_inc_compiles(self):
        tasm = self._compile(ROOT / "sw/compiler/examples/atomic_inc.c")
        prog = assemble(tasm, name="atomic_inc_c")
        self.assertGreater(len(prog.words), 0)
        # CAA must round-trip through the assembler
        self.assertIn("CAA", tasm)

    def test_compile_error_on_unsupported(self):
        # Recursion is not in the SCoP subset.
        bad = (ROOT / "sw/compiler/examples").parent / ".bad.c"
        bad.write_text(
            "uint64_t bad(uint64_t x) {\n"
            "  return bad(x);\n"
            "}\n"
        )
        try:
            with self.assertRaises(CompileError):
                self._compile(bad)
        finally:
            try: bad.unlink()
            except Exception: pass

    @unittest.skipUnless(SIM.exists(),
        "simulator not built — run `make sim` first")
    def test_graph_walk_runs(self):
        tasm = self._compile(ROOT / "sw/compiler/examples/graph_walk.c")
        prog = assemble(tasm, name="graph_walk_c")
        with tempfile.NamedTemporaryFile(
                "wb", suffix=".bin", delete=False) as f:
            f.write(prog.to_bin()); op_path = f.name
        # Seed: 4 nodes, each (data, next).  Following 3 hops from
        # node 0 lands at node 3 with data=300.
        seed_lines = []
        for i in range(4):
            seed_lines.append(f"{i*100:016x}")
            seed_lines.append(f"{(i+1)*16:016x}")
        with tempfile.NamedTemporaryFile(
                "w", suffix=".hex", delete=False) as f:
            f.write("\n".join(seed_lines) + "\n"); seed_path = f.name
        out = subprocess.run(
            [str(SIM), "--op", op_path, "--dma", seed_path,
             "--args", "0,3", "--cycles", "50000"],
            capture_output=True, text=True, check=True)
        for line in out.stdout.splitlines():
            if line.startswith("RESULT"):
                parts = dict(p.split("=", 1) for p in line[7:].split())
                self.assertEqual(parts["err"], "0")
                self.assertEqual(int(parts["r0"], 16), 300,
                                 msg=f"unexpected result: {line}")
                return
        self.fail(f"no RESULT line in output:\n{out.stdout}")


if __name__ == "__main__":
    unittest.main()
