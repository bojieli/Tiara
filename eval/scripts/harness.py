"""
Tiara evaluation harness — Python driver around the Verilator simulator.

For each workload:
  1. assemble the operator (sw/asm)
  2. statically verify it (sw/verifier)
  3. build a host-DRAM seed image
  4. invoke `Vtiara_nic_top` with the operator + seed
  5. parse `RESULT cycles=...` and convert to wall-time at 200 MHz

Also implements analytical baselines (RDMA / RPC / RedN / PRISM) sharing
the same physical parameters as `eval/simulator.py`, so all numbers
in `eval/results/*.dat` come out of one entry point.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sw" / "asm"))
sys.path.insert(0, str(ROOT / "sw" / "verifier"))

from tiara_asm import assemble_file        # noqa: E402
from tiara_verifier import (                # noqa: E402
    load_manifest, verify, VerifyError,
)
from tiara_isa import make_addr             # noqa: E402


SIM_BIN  = ROOT / "sim" / "verilator" / "build" / "Vtiara_nic_top"
CLOCK_HZ = 200_000_000
US_PER_CYCLE = 1e6 / CLOCK_HZ              # 5 ns -> 0.005 µs


# ---------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------

def build_operator(tasm_path: Path) -> Tuple[List[int], Path]:
    """Assemble + verify a `.tasm` file.  Returns (words, binary_path)."""
    prog = assemble_file(tasm_path)
    manifest_path = tasm_path.with_suffix(".toml")
    manifest = load_manifest(manifest_path)
    rep = verify(prog, manifest)
    if not rep.ok:
        raise VerifyError(f"verify failed: {rep.issues}")
    bin_path = tasm_path.with_suffix(".bin")
    bin_path.write_bytes(prog.to_bin())
    return prog.words, bin_path


def write_hex_seed(words: List[int], path: Path):
    path.write_text("\n".join(f"{w:016x}" for w in words) + "\n")


# ---------------------------------------------------------------------
# Simulator invocation
# ---------------------------------------------------------------------

@dataclass
class SimResult:
    cycles:    int
    err:       bool
    instr:     int
    regs:      List[int] = field(default_factory=list)
    latency_us: float = 0.0


_RES_RE = re.compile(
    r"RESULT\s+cycles=(\d+)\s+err=(\d+)\s+instr_retired=(\d+)\s+"
    r"r0=([0-9a-f]+)\s+r1=([0-9a-f]+)\s+r2=([0-9a-f]+)\s+r3=([0-9a-f]+)"
)


def run_sim(op_bin: Path, args: List[int],
            dma_seed: Optional[Path] = None,
            peer_seeds: Optional[Dict[int, Path]] = None,
            cycles: int = 5_000_000) -> SimResult:
    if not SIM_BIN.exists():
        raise FileNotFoundError(
            f"simulator binary not built: {SIM_BIN}\n"
            f"run `make -C sim/verilator` first")
    cmd = [str(SIM_BIN), "--op", str(op_bin),
           "--cycles", str(cycles),
           "--args", ",".join(str(a) for a in args)]
    if dma_seed:
        cmd += ["--dma", str(dma_seed)]
    for dev, p in (peer_seeds or {}).items():
        cmd += ["--peer", f"{dev}@{p}"]
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    m = _RES_RE.search(out.stdout)
    if not m:
        raise RuntimeError(
            f"simulator did not produce RESULT line.\n"
            f"stdout:\n{out.stdout}\nstderr:\n{out.stderr}")
    cycles = int(m.group(1))
    err    = bool(int(m.group(2)))
    instr  = int(m.group(3))
    regs   = [int(m.group(i), 16) for i in (4, 5, 6, 7)]
    return SimResult(cycles=cycles, err=err, instr=instr, regs=regs,
                     latency_us=cycles * US_PER_CYCLE)


# ---------------------------------------------------------------------
# Analytical baselines (kept in sync with eval/simulator.py)
# ---------------------------------------------------------------------

@dataclass
class Params:
    rtt_us:    float = 2.5
    pcie_us:   float = 0.75
    rpc_dispatch_us: float = 1.5
    rpc_local_mem_us: float = 0.17
    redn_per_hop_us: float = 1.1
    prism_per_hop_us: float = 0.5


def baseline_rdma_graph(depth: int, p: Params) -> float:
    return depth * p.rtt_us


def baseline_rpc_graph(depth: int, p: Params) -> float:
    return p.rtt_us + p.rpc_dispatch_us + depth * p.rpc_local_mem_us


def baseline_redn_graph(depth: int, p: Params) -> float:
    return p.rtt_us + depth * p.redn_per_hop_us


def baseline_prism_graph(depth: int, p: Params) -> float:
    return p.rtt_us + depth * p.prism_per_hop_us


def baseline_rdma_pt() -> float:
    p = Params()
    return 4 * p.rtt_us  # 3 walk RTTs + 1 data RTT


def baseline_rpc_pt() -> float:
    p = Params()
    return p.rtt_us + p.rpc_dispatch_us + 3 * p.rpc_local_mem_us


def baseline_rdma_dist_lock() -> float:
    return 5 * Params().rtt_us


def baseline_rdma_paged_attn(num_blocks: int, block_bytes: int) -> float:
    p = Params()
    # Optimally batched: 1 RTT for block table + 1 RTT for all blocks +
    # client-side WR construction overhead.
    bw_us = (num_blocks * block_bytes) / (12_100.0)   # 12.1 GB/s
    wr_overhead = 1.2 * num_blocks
    return 2 * p.rtt_us + bw_us + wr_overhead


# ---------------------------------------------------------------------
# Workload-specific drivers
# ---------------------------------------------------------------------

def _seed_graph(num_nodes: int, depth: int, base_word: int = 0
                ) -> Tuple[List[Tuple[int, int]], int, List[int]]:
    """Build a simple linked-list graph with pointers chained 0->1->2->...

    Returns the list of (data, next) pairs, the start address (byte
    offset within device 0), and the seed words (one 64b word per
    field).  Each node occupies 16 bytes (data 8 + next 8).
    """
    n = max(num_nodes, depth + 2)
    nodes = []
    words: List[int] = []
    for i in range(n):
        data = 0xDEC0DE00 + i
        nxt_byte_offset = (i + 1) * 16 if i + 1 < n else 0
        nodes.append((data, nxt_byte_offset))
        words.append(data)
        words.append(nxt_byte_offset)
    return nodes, 0, words


def cmd_graph_traversal(args):
    """Run depth=1..10 graph-walk on the simulator."""
    tasm = ROOT / "sw" / "operators" / "graph_walk.tasm"
    _, op_bin = build_operator(tasm)

    results = []
    for d in range(1, args.max_depth + 1):
        nodes, start, words = _seed_graph(d + 4, d)
        # The hex seed file has one 64b word per line, written into host
        # DRAM at words[0..N-1].
        with tempfile.NamedTemporaryFile(
                "w", suffix=".hex", delete=False) as f:
            f.write("\n".join(f"{w:016x}" for w in words) + "\n")
            seed = Path(f.name)
        try:
            r = run_sim(op_bin, args=[start, d, 0, 0, 0, 0, 0, 0],
                        dma_seed=seed)
        finally:
            seed.unlink(missing_ok=True)
        if r.err:
            print(f"  d={d}: ERROR after {r.cycles} cycles", file=sys.stderr)
            continue
        # Sanity: r0 of the result should be the data field of the
        # final node visited (node index `d`).
        expected = 0xDEC0DE00 + d
        ok = r.regs[0] == expected
        results.append((d, r.latency_us, r.cycles, ok))
        print(f"  depth={d:2d}  Tiara={r.latency_us:6.2f} µs  "
              f"({r.cycles} cycles)  ok={ok}")

    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("w") as f:
            f.write("# Graph traversal latency (µs)\n")
            f.write("# depth Tiara_RTL  RDMA   RPC    RedN   PRISM\n")
            p = Params()
            for d, lat, cyc, _ok in results:
                f.write(f"{d:<6d}{lat:8.2f}{baseline_rdma_graph(d,p):8.2f}"
                        f"{baseline_rpc_graph(d,p):8.2f}"
                        f"{baseline_redn_graph(d,p):8.2f}"
                        f"{baseline_prism_graph(d,p):8.2f}\n")
        print(f"wrote {out}")
    return 0


def cmd_page_table_walk(args):
    """Run a 3-level page-table walk."""
    tasm = ROOT / "sw" / "operators" / "page_table_walk.tasm"
    _, op_bin = build_operator(tasm)

    # Layout:
    #   L1 table at byte offset 0          (512 entries, each 8 B)
    #   L2 table at byte offset 4096
    #   L3 table at byte offset 8192
    #   Data page at byte offset 12288     (4096 bytes -> 512 words)
    #   Recv buffer at byte offset 65536
    L1_BASE   = 0
    L2_BASE   = 4096
    L3_BASE   = 8192
    DATA_BASE = 12288
    DST_BASE  = 65536
    PAGE_BYTES = 4096
    # Choose a vaddr that picks index 1 at every level
    vaddr = (1 << 30) | (1 << 21) | (1 << 12)
    words: Dict[int, int] = {}
    # L1[1] -> L2_BASE
    words[(L1_BASE + 1 * 8) // 8] = L2_BASE
    # L2[1] -> L3_BASE
    words[(L2_BASE + 1 * 8) // 8] = L3_BASE
    # L3[1] -> DATA_BASE
    words[(L3_BASE + 1 * 8) // 8] = DATA_BASE
    # Fill data page
    for i in range(PAGE_BYTES // 8):
        words[(DATA_BASE // 8) + i] = 0xCAFE_0000_0000 + i

    n = max(words.keys()) + 1
    seed_words = [words.get(i, 0) for i in range(n)]
    with tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False) as f:
        f.write("\n".join(f"{w:016x}" for w in seed_words) + "\n")
        seed = Path(f.name)
    try:
        r = run_sim(op_bin,
                    args=[vaddr, L1_BASE, DST_BASE, 0, 0, 0, 0, 0],
                    dma_seed=seed)
    finally:
        seed.unlink(missing_ok=True)
    p = Params()
    print(f"  Tiara: {r.latency_us:6.2f} µs ({r.cycles} cycles, "
          f"phys=0x{r.regs[0]:x}, ok={r.regs[0] == DATA_BASE})")
    print(f"  RDMA:  {baseline_rdma_pt():6.2f} µs (4 RTTs)")
    print(f"  RPC:   {baseline_rpc_pt():6.2f} µs (1 RTT + dispatch)")
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(
            "# Page-table walk latency (µs)\n"
            "# system  latency_us\n"
            f"Tiara  {r.latency_us:.2f}\n"
            f"RDMA   {baseline_rdma_pt():.2f}\n"
            f"RPC    {baseline_rpc_pt():.2f}\n"
        )
        print(f"wrote {out}")
    return 0


def _emit_paged_attention_tasm(block_size: int) -> str:
    """Emit a PagedAttention operator with the block size baked into the
    immediate field of the MEMCPY (the RTL's LEN_FROM_REG path is left
    for future work; constant block sizes are sufficient to characterise
    per-block overhead, which is the metric the paper reports)."""
    return f"""\
  .arg btbase  r1
  .arg nblock  r2
  .arg dst     r3

  ADDI r5, r1, 0
  ADDI r6, r3, 0

  LOOP r2, body_end
  LOAD   r8, [r5 + 0]
  MEMCPY r9, r6, r8, ASYNC, LEN={block_size}
  ADDI   r5, r5, 8
  ADDI   r6, r6, {block_size}
body_end:
  WAIT 0
  LI   r1, 0
  RET  r1
"""


def cmd_paged_attention(args):
    """PagedAttention block gather.

    Vary block size with a fixed total payload (8 MB) and report
    achieved throughput.
    """
    TOTAL_BYTES = 8 * 1024 * 1024
    BLOCK_TABLE_BASE = 0
    DST_BASE = 0x100000

    rows = []
    for bsize in args.block_sizes:
        nblocks = TOTAL_BYTES // bsize
        with tempfile.NamedTemporaryFile(
                "w", suffix=".tasm", delete=False) as f:
            f.write(_emit_paged_attention_tasm(bsize))
            tasm_path = Path(f.name)
        try:
            from tiara_asm import assemble_file as _asm  # noqa
            prog = _asm(tasm_path)
            op_bin = tasm_path.with_suffix(".bin")
            op_bin.write_bytes(prog.to_bin())

            bt_words = [BLOCK_TABLE_BASE + nblocks * 8 + i * bsize
                        for i in range(nblocks)]
            data_words_count = (nblocks * bsize + 7) // 8
            seed_words = bt_words + [0] * data_words_count
            with tempfile.NamedTemporaryFile(
                    "w", suffix=".hex", delete=False) as f:
                f.write("\n".join(f"{w:016x}" for w in seed_words) + "\n")
                seed = Path(f.name)
            try:
                r = run_sim(op_bin,
                            args=[BLOCK_TABLE_BASE, nblocks, DST_BASE,
                                  0, 0, 0, 0, 0],
                            dma_seed=seed,
                            cycles=50_000_000)
            finally:
                seed.unlink(missing_ok=True)
        finally:
            tasm_path.unlink(missing_ok=True)
            tasm_path.with_suffix(".bin").unlink(missing_ok=True)

        gbps = (TOTAL_BYTES / 1e9) / (r.latency_us / 1e6)
        rows.append((bsize, r.latency_us, gbps,
                     baseline_rdma_paged_attn(nblocks, bsize)))
        print(f"  block={bsize:6d}B  blocks={nblocks:5d}  "
              f"Tiara={r.latency_us:7.1f} µs ({gbps:5.2f} GB/s)")

    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open("w") as f:
            f.write("# PagedAttention throughput\n")
            f.write("# block_bytes Tiara_us Tiara_GBps RDMA_us\n")
            for bsize, lat, gbps, rdma in rows:
                f.write(f"{bsize:<10d}{lat:10.1f}{gbps:8.2f}{rdma:10.1f}\n")
        print(f"wrote {out}")
    return 0


def cmd_summary(args):
    """Print a summary table to stdout."""
    p = Params()
    for d in (1, 5, 10):
        rtl = "?"
        print(f"depth {d}:  RDMA={baseline_rdma_graph(d,p):.2f}  "
              f"RPC={baseline_rpc_graph(d,p):.2f}  RedN={baseline_redn_graph(d,p):.2f}  "
              f"PRISM={baseline_prism_graph(d,p):.2f}")
    return 0


# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------

def main(argv: List[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Tiara evaluation harness")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("graph", help="Graph traversal benchmark")
    g.add_argument("--max-depth", type=int, default=10)
    g.add_argument("--out",       type=Path, default=None)
    g.set_defaults(func=cmd_graph_traversal)

    pt = sub.add_parser("ptwalk", help="3-level page-table walk")
    pt.add_argument("--out", type=Path, default=None)
    pt.set_defaults(func=cmd_page_table_walk)

    pa = sub.add_parser("paged", help="PagedAttention block gather")
    pa.add_argument("--block-sizes", type=int, nargs="+",
                    default=[1024, 2048, 4096, 8192, 16384, 32768,
                             65536, 131072, 262144])
    pa.add_argument("--out", type=Path, default=None)
    pa.set_defaults(func=cmd_paged_attention)

    s = sub.add_parser("summary", help="Print analytical-only summary")
    s.set_defaults(func=cmd_summary)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
