#!/usr/bin/env python3
"""Aggregate every key result into a single Markdown + CSV summary
for the paper's results table.

Reads from:
  eval/results/*.dat                — workload measurements
  reports/u50_2025.2_post_route/    — single-MP synth+impl
  reports/u50_2025.2_app_post_route/ — Tiara+Corundum app block
  synth_8mp/util_post_synth.rpt     — 8-MP synth (when available)

Writes:
  reports/SUMMARY.md
  reports/SUMMARY.csv
"""

from __future__ import annotations

import csv
import re
from pathlib import Path

ROOT     = Path(__file__).resolve().parents[1]
RESULTS  = ROOT / "eval" / "results"
REPORTS  = ROOT / "reports"


def _read_dat(path: Path) -> tuple[list[str], list[list]]:
    headers: list[list[str]] = []
    rows: list[list] = []
    if not path.exists():
        return [], []
    with path.open() as f:
        for line in f:
            line = line.rstrip()
            if line.startswith("#"):
                tokens = line.lstrip("#").split()
                if len(tokens) >= 2:
                    headers.append(tokens)
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
    h = []
    if rows:
        for c in reversed(headers):
            if len(c) == len(rows[0]):
                h = c
                break
    return h, rows


def _parse_util_rpt(path: Path) -> dict[str, int]:
    """Pull LUT/FF/BRAM36/DSP totals from a Vivado utilization report."""
    out = {}
    if not path.exists():
        return out
    text = path.read_text()
    patterns = {
        "LUT":      r"\|\s*CLB LUTs\*?\s*\|\s*(\d+)",
        "FF":       r"\|\s*CLB Registers\s*\|\s*(\d+)",
        "BRAM36":   r"\|\s*Block RAM Tile\s*\|\s*(\d+)",
        "RAMB36":   r"\|\s*RAMB36/FIFO\*?\s*\|\s*(\d+)",
        "DSP":      r"\|\s*DSPs\s*\|\s*(\d+)",
    }
    for k, pat in patterns.items():
        m = re.search(pat, text)
        if m:
            out[k] = int(m.group(1))
    return out


def _parse_timing(path: Path) -> dict[str, float]:
    out = {}
    if not path.exists():
        return out
    text = path.read_text()
    m = re.search(r"\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+\d+\s+\d+\s+(-?\d+\.\d+)", text)
    if m:
        out["WNS"] = float(m.group(1))
        out["TNS"] = float(m.group(2))
        out["WHS"] = float(m.group(3))
    return out


def main():
    sections = []
    csv_rows = []

    # ---- Workload latency / throughput summary -----------------------
    h, rows = _read_dat(RESULTS / "graph_traversal.dat")
    if rows:
        d_idx = h.index("depth")
        t_idx = h.index("Tiara_RTL")
        r_idx = h.index("RDMA")
        rows_d1  = next(r for r in rows if r[d_idx] == 1)
        rows_d10 = next(r for r in rows if r[d_idx] == 10)
        sections.append(("Graph traversal latency (µs)", [
            ("depth=1",  f"{rows_d1[t_idx]:.2f}",  f"{rows_d1[r_idx]:.2f}",
             f"{rows_d1[r_idx] / rows_d1[t_idx]:.1f}x"),
            ("depth=10", f"{rows_d10[t_idx]:.2f}", f"{rows_d10[r_idx]:.2f}",
             f"{rows_d10[r_idx] / rows_d10[t_idx]:.1f}x"),
        ], ["Workload", "Tiara (µs)", "RDMA (µs)", "Speedup"]))
        csv_rows.append(("graph_d1_us",  rows_d1[t_idx]))
        csv_rows.append(("graph_d10_us", rows_d10[t_idx]))
        csv_rows.append(("graph_d10_speedup_vs_rdma",
                         rows_d10[r_idx] / rows_d10[t_idx]))

    h, rows = _read_dat(RESULTS / "pt_walk.dat")
    if rows:
        sys_idx = h.index("system")
        lat_idx = h.index("latency_us")
        d = {r[sys_idx]: r[lat_idx] for r in rows}
        if "Tiara" in d and "RDMA" in d:
            sections.append(("Page-table walk latency (µs)", [
                ("Tiara",  f"{d['Tiara']:.2f}", "-",  "-"),
                ("RDMA",   f"{d['RDMA']:.2f}",  "-",
                 f"{d['RDMA']/d['Tiara']:.1f}x"),
                ("RPC",    f"{d.get('RPC',0):.2f}", "-",  "-"),
            ], ["System", "Latency (µs)", "—", "vs Tiara"]))
            csv_rows.append(("pt_walk_tiara_us", d["Tiara"]))
            csv_rows.append(("pt_walk_speedup_vs_rdma", d["RDMA"]/d["Tiara"]))

    h, rows = _read_dat(RESULTS / "dist_lock.dat")
    if rows:
        c_idx = h.index("clients")
        t_idx = h.index("Tiara")
        r_idx = h.index("RDMA")
        r1 = next((r for r in rows if r[c_idx] == 1),  None)
        r16 = next((r for r in rows if r[c_idx] == 16), None)
        if r1 and r16:
            sections.append(("Distributed lock latency (µs)", [
                ("1 client",   f"{r1[t_idx]:.2f}",  f"{r1[r_idx]:.2f}",
                 f"{r1[r_idx]/r1[t_idx]:.2f}x"),
                ("16 clients", f"{r16[t_idx]:.2f}", f"{r16[r_idx]:.2f}",
                 f"{r16[r_idx]/r16[t_idx]:.2f}x"),
            ], ["Workload", "Tiara", "RDMA", "Speedup"]))
            csv_rows.append(("lock_1_us",  r1[t_idx]))
            csv_rows.append(("lock_16_us", r16[t_idx]))

    h, rows = _read_dat(RESULTS / "paged_attention.dat")
    if rows:
        b_idx = h.index("block_bytes")
        t_idx = h.index("Tiara_GBps")
        r_idx = h.index("RDMA_GBps")
        r8k = next((r for r in rows if int(r[b_idx]) == 8192),  None)
        if r8k:
            sections.append(("PagedAttention throughput (GB/s)", [
                ("8 KB blocks", f"{r8k[t_idx]:.2f}", f"{r8k[r_idx]:.2f}",
                 f"{r8k[t_idx]/r8k[r_idx]:.2f}x"),
            ], ["Block size", "Tiara GB/s", "RDMA GB/s", "Speedup"]))
            csv_rows.append(("paged_8kb_tiara_gbps", r8k[t_idx]))
            csv_rows.append(("paged_8kb_speedup_vs_rdma",
                             r8k[t_idx] / r8k[r_idx]))

    # ---- Resource & timing summary -----------------------------------
    cases = [
        ("1-MP core (post-route)",
         REPORTS / "u50_2025.2_post_route" / "util_post_route.rpt",
         REPORTS / "u50_2025.2_post_route" / "timing_post_route.rpt"),
        ("Tiara + Corundum app (post-route)",
         REPORTS / "u50_2025.2_app_post_route" / "util_post_route.rpt",
         REPORTS / "u50_2025.2_app_post_route" / "timing_post_route.rpt"),
        ("8-MP core (post-synth)",
         REPORTS / "u50_2025.2_8mp_post_synth" / "util_post_synth.rpt",
         REPORTS / "u50_2025.2_8mp_post_synth" / "timing_post_synth.rpt"),
    ]
    res_rows = []
    for name, util_path, tim_path in cases:
        u = _parse_util_rpt(util_path)
        t = _parse_timing(tim_path)
        wns = t.get("WNS", float("nan"))
        res_rows.append((
            name,
            str(u.get("LUT", "?")),
            str(u.get("FF", "?")),
            str(u.get("BRAM36", "?")),
            str(u.get("DSP", "?")),
            f"{wns:+.3f} ns" if wns == wns else "?",
        ))
        csv_rows.append((f"{name}.LUT", u.get("LUT", -1)))
        csv_rows.append((f"{name}.FF",  u.get("FF", -1)))
        csv_rows.append((f"{name}.BRAM36", u.get("BRAM36", -1)))
        csv_rows.append((f"{name}.WNS_ns", wns))
    sections.append(
        ("Vivado on Alveo U50 (xcu50-fsvh2104-2-e, 200 MHz)",
         res_rows,
         ["Configuration", "LUT", "FF", "BRAM-36", "DSP", "WNS"]))

    # ---- Output ------------------------------------------------------
    REPORTS.mkdir(exist_ok=True)
    md = REPORTS / "SUMMARY.md"
    with md.open("w") as f:
        f.write("# Tiara — headline results\n\n")
        f.write("Generated by `scripts/make_summary.py`.  Re-run after "
                "`make eval` and any `make synth` / `make impl` change.\n\n")
        for title, rows, headers in sections:
            f.write(f"## {title}\n\n")
            f.write("| " + " | ".join(headers) + " |\n")
            f.write("|" + "|".join(["---"] * len(headers)) + "|\n")
            for r in rows:
                f.write("| " + " | ".join(str(c) for c in r) + " |\n")
            f.write("\n")
    print(f"wrote {md}")

    csv_path = REPORTS / "SUMMARY.csv"
    with csv_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["metric", "value"])
        for k, v in csv_rows:
            w.writerow([k, v])
    print(f"wrote {csv_path}")


if __name__ == "__main__":
    main()
