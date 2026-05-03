"""Generate paper-style plots from `eval/results/*.dat`."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / "eval" / "results"
FIGS    = ROOT / "eval" / "figures"


def _load_columns(path: Path) -> dict:
    """Return {header_token: [values]} for a `# header` row."""
    headers: list[str] = []
    cols: dict[str, list] = {}
    rows: list[list[float]] = []
    with path.open() as f:
        for line in f:
            line = line.rstrip()
            if line.startswith("#"):
                tokens = line.lstrip("#").split()
                if any(t in line for t in ("depth", "system", "block_bytes")):
                    headers = tokens
                continue
            if not line:
                continue
            rows.append([float(x) if not x.isalpha() else x for x in line.split()])
    if not headers:
        # Best-effort: invent column names
        if rows:
            headers = [f"col{i}" for i in range(len(rows[0]))]
    for i, h in enumerate(headers):
        cols[h] = [r[i] for r in rows if i < len(r)]
    return cols


def _try_matplotlib():
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        return plt
    except Exception as exc:
        print(f"matplotlib unavailable ({exc!r}); skipping plot rendering",
              file=sys.stderr)
        return None


def plot_graph(plt):
    p = RESULTS / "graph_traversal.dat"
    if not p.exists():
        return
    cols = _load_columns(p)
    fig, ax = plt.subplots(figsize=(4.5, 3.0))
    depths = cols["depth"]
    for label, key in [("Tiara",  "Tiara_RTL"),
                       ("RDMA",   "RDMA"),
                       ("RPC",    "RPC"),
                       ("RedN",   "RedN"),
                       ("PRISM",  "PRISM")]:
        if key in cols:
            ax.plot(depths, cols[key], marker="o", label=label)
    ax.set_xlabel("Traversal depth (hops)")
    ax.set_ylabel("Latency (µs)")
    ax.set_title("Graph traversal latency vs. depth")
    ax.legend(); ax.grid(True, alpha=0.3)
    out = FIGS / "graph_traversal.png"
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    print(f"wrote {out}")


def plot_ptwalk(plt):
    p = RESULTS / "pt_walk.dat"
    if not p.exists():
        return
    cols = _load_columns(p)
    if "system" not in cols:
        return
    fig, ax = plt.subplots(figsize=(3.5, 2.8))
    sys_names = cols["system"]
    lats      = cols.get("latency_us", [])
    if not lats and "col1" in cols:
        lats = cols["col1"]
    ax.bar(sys_names, lats, color=["#1f77b4", "#d62728", "#2ca02c"])
    ax.set_ylabel("Latency (µs)")
    ax.set_title("Page-table walk")
    for i, v in enumerate(lats):
        ax.text(i, v, f"{v:.1f}", ha="center", va="bottom")
    out = FIGS / "pt_walk.png"
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    print(f"wrote {out}")


def plot_paged(plt):
    p = RESULTS / "paged_attention.dat"
    if not p.exists():
        return
    cols = _load_columns(p)
    fig, ax = plt.subplots(figsize=(4.5, 3.0))
    bs = cols.get("block_bytes", [])
    tg = cols.get("Tiara_GBps", [])
    if bs and tg:
        ax.plot(bs, tg, marker="o", label="Tiara (sim)")
    if "Tiara_us" in cols and "RDMA_us" in cols and bs:
        # Compute RDMA throughput from RDMA_us and total payload (8 MB)
        rdma_gbps = [(8 * 1024 * 1024 / 1e9) / (us / 1e6)
                     for us in cols["RDMA_us"]]
        ax.plot(bs, rdma_gbps, marker="s", label="RDMA (analytical)")
    ax.set_xscale("log", base=2)
    ax.set_xlabel("Block size (bytes)")
    ax.set_ylabel("Effective throughput (GB/s)")
    ax.set_title("PagedAttention throughput vs. block size")
    ax.legend(); ax.grid(True, alpha=0.3)
    out = FIGS / "paged_attention.png"
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    print(f"wrote {out}")


def main() -> int:
    plt = _try_matplotlib()
    if plt is None:
        return 0
    FIGS.mkdir(parents=True, exist_ok=True)
    plot_graph(plt)
    plot_ptwalk(plt)
    plot_paged(plt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
