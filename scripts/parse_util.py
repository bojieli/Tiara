#!/usr/bin/env python3
"""Parse a Vivado utilization report and produce a paper-comparison
summary.

Usage:
    python3 scripts/parse_util.py synth/util_post_synth.rpt
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


# Paper §4.1 claim: ~64K LUTs, ~78 BRAMs, ~8% of U50 for the 8-MP design.
# U50 totals (xcu50-fsvh2104-2-e):
U50_LUTS    = 870_720
U50_FFS     = 1_741_440
U50_BRAM36  = 1_344
U50_URAM    = 640
U50_DSP     = 5_952

PAPER_CLAIM_LUTS  = 64_000
PAPER_CLAIM_BRAMS = 78


def _grab_int(line: str) -> int:
    """Pull the leftmost large integer out of a Vivado report line."""
    nums = re.findall(r"\b(\d{1,9})\b", line)
    if not nums:
        return 0
    # The Vivado layout is | name | used | available | util |.  We take
    # the first column after the name, which is "used".
    return int(nums[0])


def parse(path: Path) -> dict:
    text = path.read_text(errors="replace")
    metrics: dict[str, int] = {}

    def find(label: str) -> int:
        for line in text.splitlines():
            if line.lstrip().startswith("|") and label in line:
                cells = [c.strip() for c in line.strip("|").split("|")]
                # Expect: <name>, <used>, <fixed>, <prohibited>, <available>, <util%>
                # Column count varies between vivado versions.  Pick the
                # first integer-looking cell after the name.
                for c in cells[1:]:
                    if c.replace(",", "").replace(".", "").isdigit():
                        return int(c.replace(",", "").split(".")[0])
                return _grab_int(line)
        return -1

    metrics["LUT"]   = find("CLB LUTs")
    metrics["LUTRAM"] = find("LUT as Memory")
    metrics["FF"]    = find("CLB Registers")
    metrics["BRAM_TILE"] = find("Block RAM Tile")
    metrics["BRAM_36K"]  = find("RAMB36/FIFO")
    metrics["BRAM_18K"]  = find("RAMB18")
    metrics["URAM"]      = find("URAM")
    metrics["DSP"]       = find("DSPs")
    return metrics


def fmt(n: int, total: int | None = None) -> str:
    if n < 0:
        return "n/a"
    if total:
        return f"{n:,} ({100 * n / total:.2f}%)"
    return f"{n:,}"


def main(argv):
    if len(argv) != 2:
        print("usage: parse_util.py <util_report.rpt>", file=sys.stderr)
        return 2
    p = Path(argv[1])
    if not p.exists():
        print(f"file not found: {p}", file=sys.stderr)
        return 2
    m = parse(p)

    print(f"# Tiara utilization summary  (source: {p})")
    print(f"# Target: xcu50-fsvh2104-2-e (Alveo U50)")
    print(f"#")
    print(f"# Resource     Used               Paper claim (8 MPs)")
    print(f"  LUT          {fmt(m['LUT'], U50_LUTS):<22s}{PAPER_CLAIM_LUTS:>8d} (~7.4%)")
    print(f"  LUT-as-mem   {fmt(m['LUTRAM']):<22s}-")
    print(f"  Reg (FF)     {fmt(m['FF'], U50_FFS):<22s}-")
    print(f"  BRAM tile    {fmt(m['BRAM_TILE'], U50_BRAM36):<22s}{PAPER_CLAIM_BRAMS:>8d} (~5.8%)")
    print(f"  RAMB36       {fmt(m['BRAM_36K']):<22s}-")
    print(f"  RAMB18       {fmt(m['BRAM_18K']):<22s}-")
    print(f"  URAM         {fmt(m['URAM'], U50_URAM):<22s}-")
    print(f"  DSP          {fmt(m['DSP'], U50_DSP):<22s}-")
    print()
    if m["LUT"] >= 0:
        scale = m["LUT"] / 1.0  # this build is single-MP
        ext = scale * 8         # estimated 8-MP cost
        print(f"Single-MP build measured here.  Linear extrapolation to "
              f"8 MPs:")
        print(f"    LUT × 8 ≈ {ext:,.0f}  vs paper {PAPER_CLAIM_LUTS:,}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
