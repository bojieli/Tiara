#!/usr/bin/env python3
"""Generate golden vectors from the Python reference + Verilator sim.

Emits web/src/engine/golden.json:
  - encodings: for each named program, the assembled 64-bit words (hex)
  - runs: for chosen (program, args, dma seed) cases, the Verilator
    sim's cycles / err / r0..r3 — the oracle for the TS VM.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

TIARA = Path("/home/ubuntu/Tiara")
sys.path.insert(0, str(TIARA / "sw" / "asm"))
from tiara_asm import assemble, assemble_file  # noqa: E402

SIM = TIARA / "sim" / "verilator" / "build" / "Vtiara_nic_top"
OPS = TIARA / "sw" / "operators"


def run_sim(words, args, dma_words=None, peers=None, cycles=2_000_000):
    with tempfile.NamedTemporaryFile("wb", suffix=".bin", delete=False) as f:
        for w in words:
            f.write(w.to_bytes(8, "little"))
        binp = Path(f.name)
    seed = None
    if dma_words is not None:
        with tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False) as f:
            f.write("\n".join(f"{w:016x}" for w in dma_words) + "\n")
            seed = Path(f.name)
    peer_paths = {}
    for dev, pw in (peers or {}).items():
        with tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False) as f:
            f.write("\n".join(f"{w:016x}" for w in pw) + "\n")
            peer_paths[dev] = Path(f.name)
    cmd = [str(SIM), "--op", str(binp), "--cycles", str(cycles),
           "--args", ",".join(str(a) for a in args)]
    if seed:
        cmd += ["--dma", str(seed)]
    for dev, p in peer_paths.items():
        cmd += ["--peer", f"{dev}@{p}"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    binp.unlink(missing_ok=True)
    if seed:
        seed.unlink(missing_ok=True)
    for p in peer_paths.values():
        p.unlink(missing_ok=True)
    for line in out.stdout.splitlines():
        if line.startswith("RESULT "):
            parts = dict(p.split("=", 1) for p in line[7:].split())
            return {
                "cycles": int(parts["cycles"]),
                "err": bool(int(parts["err"])),
                "regs": [parts[f"r{i}"] for i in range(4)],  # hex strings
            }
    raise RuntimeError(f"no RESULT:\n{out.stdout}\n{out.stderr}")


def enc(words):
    return [f"{w:016x}" for w in words]


def main():
    golden = {"encodings": {}, "runs": []}

    # --- encodings of the shipped operators ---
    for name in ["graph_walk", "page_table_walk", "dist_lock",
                 "moe_expert", "paged_attention"]:
        prog = assemble_file(OPS / f"{name}.tasm")
        golden["encodings"][name] = enc(prog.words)

    # --- inline programs (mirror sim_test.py) + run vectors ---
    cases = [
        ("immediate", "LI r1, 0x1234\nRET r1", [0] * 8, None, None),
        ("addi", "ADDI r1, r1, 100\nRET r1", [42] + [0] * 7, None, None),
        ("load", "LOAD r1, [r1 + 0]\nRET r1", [0] * 8, [0xCAFEBABE], None),
        ("load_chain",
         "ADDI r5, r1, 0\nLOAD r5, [r5 + 0]\nLOAD r5, [r5 + 0]\n"
         "LOAD r5, [r5 + 0]\nLOAD r5, [r5 + 0]\nADDI r1, r5, 0\nRET r1",
         [0] * 8, [8, 16, 24, 0xCAFE], None),
        ("loop",
         "LOOP r1, body_end\nADDI r2, r2, 1\nbody_end:\nADDI r1, r2, 0\nRET r1",
         [5] + [0] * 7, None, None),
        ("loop_with_load",
         "ADDI r5, r1, 0\nLOOP r2, body_end\nLOAD r5, [r5 + 0]\n"
         "body_end:\nADDI r1, r5, 0\nRET r1",
         [0, 3] + [0] * 6, [8, 16, 24, 0xCAFE], None),
    ]
    for name, src, args, dma, peers in cases:
        prog = assemble(src, name=name)
        golden["encodings"][name] = enc(prog.words)
        res = run_sim(prog.words, args, dma_words=dma, peers=peers)
        golden["runs"].append({
            "name": name, "src": src, "args": args,
            "dma": dma, "peers": peers, "expect": res,
        })

    # --- operator run vectors (with realistic seeds) ---
    # graph_walk depth 1..5
    for d in range(1, 6):
        nn = d + 4
        words = []
        for i in range(nn):
            words.append(0xDEC0DE00 + i)
            words.append((i + 1) * 16 if i + 1 < nn else 0)
        prog = assemble_file(OPS / "graph_walk.tasm")
        res = run_sim(prog.words, [0, d, 0, 0, 0, 0, 0, 0], dma_words=words)
        golden["runs"].append({
            "name": f"graph_walk_d{d}", "op": "graph_walk",
            "args": [0, d, 0, 0, 0, 0, 0, 0], "dma": words,
            "expect": res,
        })

    # page_table_walk
    L1, L2, L3, DATA, DST = 0, 4096, 8192, 12288, 65536
    vaddr = (1 << 30) | (1 << 21) | (1 << 12)
    wmap = {}
    wmap[(L1 + 8) // 8] = L2
    wmap[(L2 + 8) // 8] = L3
    wmap[(L3 + 8) // 8] = DATA
    for i in range(4096 // 8):
        wmap[(DATA // 8) + i] = 0xCAFE_0000_0000 + i
    n = max(wmap) + 1
    seed = [wmap.get(i, 0) for i in range(n)]
    prog = assemble_file(OPS / "page_table_walk.tasm")
    res = run_sim(prog.words, [vaddr, L1, DST, 0, 0, 0, 0, 0], dma_words=seed)
    golden["runs"].append({
        "name": "page_table_walk", "op": "page_table_walk",
        "args": [vaddr, L1, DST, 0, 0, 0, 0, 0], "dma": seed,
        "expect": res,
    })

    out = TIARA / "web" / "src" / "engine" / "golden.json"
    out.write_text(json.dumps(golden, indent=1))
    print(f"wrote {out}: {len(golden['encodings'])} encodings, "
          f"{len(golden['runs'])} run vectors")


if __name__ == "__main__":
    main()
