"""Generate paper-style plots from `eval/results/*.dat`."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESULTS = ROOT / "eval" / "results"
FIGS    = ROOT / "eval" / "figures"


def _load_columns(path: Path) -> dict:
    """Return {header_token: [values]} for a `# header` row.  The header
    is taken to be the LAST `# ...` line that has at least 2 tokens and
    whose token count matches the first data row's column count.
    """
    candidate_headers: list[list[str]] = []
    cols: dict[str, list] = {}
    rows: list[list] = []
    with path.open() as f:
        for line in f:
            line = line.rstrip()
            if line.startswith("#"):
                tokens = line.lstrip("#").split()
                if len(tokens) >= 2:
                    candidate_headers.append(tokens)
                continue
            if not line:
                continue
            row = []
            for x in line.split():
                try:
                    row.append(float(x))
                except ValueError:
                    row.append(x)
            rows.append(row)
    headers: list[str] = []
    if rows:
        for c in reversed(candidate_headers):
            if len(c) == len(rows[0]):
                headers = c
                break
        if not headers:
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


def plot_graph_tput(plt):
    p = RESULTS / "graph_traversal_tput.dat"
    if not p.exists():
        return
    cols = _load_columns(p)
    if "depth" not in cols:
        return
    fig, ax = plt.subplots(figsize=(4.5, 3.0))
    depths = cols["depth"]
    for label, key in [("Tiara",  "Tiara_RTL"),
                       ("RDMA",   "RDMA"),
                       ("RPC",    "RPC"),
                       ("RedN",   "RedN"),
                       ("PRISM",  "PRISM")]:
        if key in cols:
            ax.plot(depths, cols[key], marker="o", label=label)
    ax.set_yscale("log")
    ax.set_xlabel("Traversal depth (hops)")
    ax.set_ylabel("Throughput (Mops, log)")
    ax.set_title("Graph traversal throughput (saturated, 8 MPs)")
    ax.legend(); ax.grid(True, alpha=0.3, which="both")
    out = FIGS / "graph_throughput.png"
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    print(f"wrote {out}")


def plot_dist_lock(plt):
    p = RESULTS / "dist_lock.dat"
    if not p.exists():
        return
    cols = _load_columns(p)
    if "clients" not in cols:
        return
    fig, ax = plt.subplots(figsize=(4.5, 3.0))
    clients = cols["clients"]
    for label, key in [("Tiara", "Tiara"), ("RDMA", "RDMA"),
                       ("RPC", "RPC"),     ("RedN", "RedN")]:
        if key in cols:
            ax.plot(clients, cols[key], marker="o", label=label)
    ax.set_xlabel("Contending clients")
    ax.set_ylabel("Latency (µs)")
    ax.set_title("Distributed lock acquisition under contention")
    ax.legend(); ax.grid(True, alpha=0.3)
    out = FIGS / "dist_lock.png"
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    print(f"wrote {out}")


def plot_crossover(plt):
    p = RESULTS / "crossover.dat"
    if not p.exists():
        return
    cols = _load_columns(p)
    if "host_mem_us" not in cols:
        return
    fig, ax = plt.subplots(figsize=(4.5, 3.0))
    hm = cols["host_mem_us"]
    if "offload_us" in cols:
        ax.plot(hm, cols["offload_us"], label="SmartNIC offload (n × host_mem + dispatch)")
    if "rdma_us" in cols:
        ax.plot(hm, cols["rdma_us"], label="One-sided RDMA (n × RTT)")
    ax.axvline(2.5, color="gray", linestyle="--", alpha=0.5,
               label="Crossover = RTT (2.5 µs)")
    ax.axvline(0.75, color="green", linestyle=":", alpha=0.7,
               label="Tiara FPGA PCIe (0.75 µs)")
    ax.set_xlabel("Host-memory access latency (µs)")
    ax.set_ylabel("Total latency (µs)")
    ax.set_title("Crossover: SmartNIC offload vs one-sided RDMA")
    ax.legend(fontsize=8); ax.grid(True, alpha=0.3)
    out = FIGS / "crossover.png"
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    print(f"wrote {out}")


def plot_paged_baselines(plt):
    """Updated paged-attention plot with all baselines."""
    p = RESULTS / "paged_attention.dat"
    if not p.exists():
        return
    cols = _load_columns(p)
    if "block_bytes" not in cols:
        return
    bs = cols["block_bytes"]
    fig, ax = plt.subplots(figsize=(4.5, 3.0))
    if "Tiara_GBps" in cols:  ax.plot(bs, cols["Tiara_GBps"], marker="o", label="Tiara (RTL)")
    if "RDMA_GBps"  in cols:  ax.plot(bs, cols["RDMA_GBps"],  marker="s", label="RDMA (batched)")
    if "RPC_GBps"   in cols:  ax.plot(bs, cols["RPC_GBps"],   marker="^", label="RPC")
    if "RedN_GBps"  in cols:  ax.plot(bs, cols["RedN_GBps"],  marker="d", label="RedN")
    ax.set_xscale("log", base=2)
    ax.set_xlabel("Block size (bytes, log)")
    ax.set_ylabel("Throughput (GB/s)")
    ax.set_title("PagedAttention throughput vs block size")
    ax.legend(); ax.grid(True, alpha=0.3, which="both")
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
    plot_graph_tput(plt)
    plot_ptwalk(plt)
    plot_paged_baselines(plt)
    plot_dist_lock(plt)
    plot_crossover(plt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
