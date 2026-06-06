"""Generate publication-quality plots from `eval/results/*.dat`.

Output formats: PNG (preview), PDF (camera-ready), EPS (legacy).  All
use Type-1 fonts (matplotlib `pdf.fonttype=42`), serif Computer Modern,
8pt body / 9pt axis labels matching ACM acmart.  Single-column figures
are 3.4 inches wide; double-column 7.0 inches.

Color palette is the colorblind-safe Tableau 8-color set, used
consistently across every figure so a reader can identify a system at
a glance.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT    = Path(__file__).resolve().parents[2]
RESULTS = ROOT / "eval" / "results"
FIGS    = ROOT / "eval" / "figures"


# ---------------------------------------------------------------------
# Style — applied once at import time so every figure looks the same.
# ---------------------------------------------------------------------
def _setup_matplotlib():
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as exc:
        print(f"matplotlib unavailable ({exc!r}); skipping plot rendering",
              file=sys.stderr)
        return None
    matplotlib.rcParams.update({
        "pdf.fonttype":      42,        # TrueType (works as Type-1 in PDF/EPS)
        "ps.fonttype":       42,
        "font.family":       "serif",
        "font.serif":        ["DejaVu Serif", "Computer Modern Roman", "Times"],
        "font.size":          8,
        "axes.titlesize":     9,
        "axes.labelsize":     9,
        "xtick.labelsize":    8,
        "ytick.labelsize":    8,
        "legend.fontsize":    7.5,
        "legend.frameon":     False,
        "axes.spines.top":    False,
        "axes.spines.right":  False,
        "axes.grid":          True,
        "grid.alpha":         0.25,
        "grid.linestyle":     ":",
        "lines.linewidth":    1.4,
        "lines.markersize":   4,
        "axes.prop_cycle":    matplotlib.rcParamsDefault["axes.prop_cycle"],
    })
    # Colorblind-safe palette (Wong 2011) — first 6 are paired so
    # graph_traversal: Tiara=blue, RDMA=red, RPC=green, RedN=orange,
    # PRISM=purple by index in the line list.
    matplotlib.rcParams["axes.prop_cycle"] = matplotlib.cycler(
        color=[
            "#0072B2",  # blue       — Tiara
            "#D55E00",  # vermillion — RDMA
            "#009E73",  # green      — RPC
            "#E69F00",  # orange     — RedN
            "#CC79A7",  # pink       — PRISM
            "#56B4E9",  # sky blue
            "#F0E442",  # yellow
            "#000000",  # black
        ])
    return plt


SYSTEM_LABELS = {
    "Tiara_RTL": "Tiara",
    "Tiara":     "Tiara",
    "RDMA":      "RDMA (one-sided)",
    "RPC":       "RPC (eRPC-style)",
    "RedN":      "RedN",
    "PRISM":     "PRISM",
}


# ---------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------
def _load_columns(path: Path) -> dict:
    """Return {header_token: [values]}.  Header is the LAST `# ...` line
    that has the same number of tokens as the first data row."""
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


def _save(fig, name: str):
    """Save the figure as PNG + PDF + EPS (all three for camera-ready
    flexibility).  PNG is for previews and READMEs; PDF/EPS for the
    paper itself."""
    FIGS.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    for ext in ("png", "pdf", "eps"):
        out = FIGS / f"{name}.{ext}"
        try:
            fig.savefig(out, dpi=300, bbox_inches="tight")
            print(f"wrote {out}")
        except Exception as exc:
            print(f"  (skipping {out}: {exc})", file=sys.stderr)


# ---------------------------------------------------------------------
# Individual figures
# ---------------------------------------------------------------------
def plot_graph_latency(plt):
    p = RESULTS / "graph_traversal.dat"
    if not p.exists(): return
    cols = _load_columns(p)
    fig, ax = plt.subplots(figsize=(3.4, 2.3))
    depths = cols["depth"]
    for label, key, marker, ls in [
            ("Tiara",  "Tiara_RTL", "o", "-"),
            ("RDMA",   "RDMA",       "s", "-"),
            ("RPC",    "RPC",        "^", "-"),
            ("RedN",   "RedN",       "D", "--"),
            ("PRISM",  "PRISM",      "v", "--")]:
        if key in cols:
            ax.plot(depths, cols[key], marker=marker, linestyle=ls,
                    label=label)
    ax.set_xlabel("Traversal depth (hops)")
    ax.set_ylabel("Latency ($\\mu$s)")
    ax.set_xticks(range(1, max([int(d) for d in depths]) + 1, 1))
    ax.set_xlim(left=0.7, right=max([int(d) for d in depths]) + 0.3)
    ax.legend(loc="upper left", ncol=1)
    _save(fig, "graph_traversal")


def plot_graph_throughput(plt):
    p = RESULTS / "graph_traversal_tput.dat"
    if not p.exists(): return
    cols = _load_columns(p)
    fig, ax = plt.subplots(figsize=(3.4, 2.3))
    depths = cols["depth"]
    for label, key, marker, ls in [
            ("Tiara",       "Tiara_RTL", "o", "-"),
            ("RDMA",        "RDMA",       "s", "-"),
            ("RPC (16c)",   "RPC",        "^", "-"),
            ("RPC (22c)",   "RPC22",      "^", ":"),
            ("RedN",        "RedN",       "D", "--"),
            ("PRISM",       "PRISM",      "v", "--")]:
        if key in cols:
            ax.plot(depths, cols[key], marker=marker, linestyle=ls,
                    label=label)
    ax.set_yscale("log")
    ax.set_xlabel("Traversal depth (hops)")
    ax.set_ylabel("Throughput (Mops, log)")
    ax.set_xticks(range(1, max([int(d) for d in depths]) + 1, 1))
    ax.set_xlim(left=0.7, right=max([int(d) for d in depths]) + 0.3)
    ax.legend(loc="lower left", ncol=2)
    _save(fig, "graph_throughput")


def plot_pt_walk(plt):
    p = RESULTS / "pt_walk.dat"
    if not p.exists(): return
    cols = _load_columns(p)
    if "system" not in cols:
        return
    fig, ax = plt.subplots(figsize=(2.6, 2.3))
    sys_names = cols["system"]
    lats = cols.get("latency_us")
    palette = ["#0072B2", "#D55E00", "#009E73"]
    bars = ax.bar(sys_names, lats, color=palette[:len(sys_names)],
                  edgecolor="black", linewidth=0.5)
    ax.set_ylabel("Latency ($\\mu$s)")
    ax.set_title("3-level page-table walk")
    for b, v in zip(bars, lats):
        ax.text(b.get_x() + b.get_width()/2, v + 0.2, f"{v:.1f}",
                ha="center", va="bottom", fontsize=7)
    ax.set_ylim(top=max(lats) * 1.18)
    _save(fig, "pt_walk")


def plot_dist_lock(plt):
    p = RESULTS / "dist_lock.dat"
    if not p.exists(): return
    cols = _load_columns(p)
    if "clients" not in cols: return
    fig, ax = plt.subplots(figsize=(3.4, 2.3))
    clients = cols["clients"]
    for label, key, marker, ls in [
            ("Tiara", "Tiara", "o", "-"),
            ("RDMA",  "RDMA",  "s", "-"),
            ("RPC",   "RPC",   "^", "-"),
            ("RedN",  "RedN",  "D", "--")]:
        if key in cols:
            ax.plot(clients, cols[key], marker=marker, linestyle=ls,
                    label=label)
    ax.set_xlabel("Contending clients")
    ax.set_ylabel("Latency ($\\mu$s)")
    ax.set_xscale("log", base=2)
    ax.set_xticks(clients)
    ax.set_xticklabels([str(int(c)) for c in clients])
    ax.legend(loc="upper left")
    _save(fig, "dist_lock")


def plot_paged(plt):
    p = RESULTS / "paged_attention.dat"
    if not p.exists(): return
    cols = _load_columns(p)
    if "block_bytes" not in cols: return
    fig, ax = plt.subplots(figsize=(3.4, 2.3))
    bs = cols["block_bytes"]
    for label, key, marker, ls in [
            ("Tiara",  "Tiara_GBps", "o", "-"),
            ("RDMA",   "RDMA_GBps",  "s", "-"),
            ("RPC",    "RPC_GBps",   "^", "-"),
            ("RedN",   "RedN_GBps",  "D", "--")]:
        if key in cols:
            ax.plot(bs, cols[key], marker=marker, linestyle=ls,
                    label=label)
    ax.set_xscale("log", base=2)
    ax.set_xlabel("KV block size (bytes, log)")
    ax.set_ylabel("Throughput (GB/s)")
    ax.legend(loc="upper left")
    _save(fig, "paged_attention")


def plot_moe(plt):
    p = RESULTS / "moe.dat"
    if not p.exists(): return
    cols = _load_columns(p)
    if "experts" not in cols: return
    fig, ax = plt.subplots(figsize=(3.4, 2.3))
    n = cols["experts"]
    for label, key, marker, ls in [
            ("Tiara", "Tiara_us", "o", "-"),
            ("RDMA",  "RDMA_us",  "s", "-"),
            ("RPC",   "RPC_us",   "^", "-")]:
        if key in cols:
            ax.plot(n, cols[key], marker=marker, linestyle=ls, label=label)
    ax.set_xscale("log", base=2)
    ax.set_xticks(n)
    ax.set_xticklabels([str(int(x)) for x in n])
    ax.set_xlabel("Experts to gather")
    ax.set_ylabel("Latency ($\\mu$s)")
    ax.legend(loc="upper left")
    _save(fig, "moe_expert")


def plot_crossover(plt):
    p = RESULTS / "crossover.dat"
    if not p.exists(): return
    cols = _load_columns(p)
    if "host_mem_us" not in cols: return
    fig, ax = plt.subplots(figsize=(3.4, 2.3))
    hm = cols["host_mem_us"]
    if "offload_us" in cols:
        ax.plot(hm, cols["offload_us"],
                label="Memory-side offload",
                color="#0072B2", linewidth=1.6)
    if "rdma_us" in cols:
        ax.plot(hm, cols["rdma_us"],
                label="One-sided RDMA",
                color="#D55E00", linewidth=1.6)
    ax.axvline(2.5, color="gray", linestyle=":", alpha=0.7)
    ax.text(2.5, ax.get_ylim()[1] * 0.95,
            " crossover\n (= RTT)", color="gray", fontsize=6.5,
            ha="left", va="top")
    ax.axvline(0.75, color="#009E73", linestyle="--", alpha=0.7)
    ax.text(0.75, ax.get_ylim()[1] * 0.55,
            " Tiara FPGA\n PCIe (0.75 µs)", color="#009E73",
            fontsize=6.5, ha="left", va="top")
    # BF-3 DPA host-memory latency reference (~0.85 µs, NVIDIA datasheet).
    # Like Tiara, DPA sits below the RTT crossover -- a viable target --
    # but still trails Tiara's hardware path (see §2.3). (BF-2's measured
    # regression is at its own 1.9 µs cable RTT, not this 2.5 µs sweep, so
    # it is shown separately in the BF-2 figure rather than as a marker here.)
    ax.axvline(0.85, color="#CC79A7", linestyle="--", alpha=0.7)
    ax.text(0.85, ax.get_ylim()[1] * 0.30,
            " BF-3 DPA\n (~0.85 µs)", color="#CC79A7",
            fontsize=6.5, ha="left", va="top")
    ax.set_xlabel("Host-memory access latency ($\\mu$s)")
    ax.set_ylabel("End-to-end latency ($\\mu$s)")
    ax.legend(loc="upper left")
    _save(fig, "crossover")


def main() -> int:
    plt = _setup_matplotlib()
    if plt is None: return 0
    plot_graph_latency(plt)
    plot_graph_throughput(plt)
    plot_pt_walk(plt)
    plot_dist_lock(plt)
    plot_paged(plt)
    plot_crossover(plt)
    plot_moe(plt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
