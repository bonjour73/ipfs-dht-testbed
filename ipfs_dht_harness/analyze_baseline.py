#!/usr/bin/env python3
"""analyze_baseline.py — summarize the centralized-baseline RACE.

Reads baseline.csv files produced by testbed/scripts/baseline_fetch.sh (one row
per leecher per trial, each row a PAIRED IPFS-vs-centralized content delivery):

    trial,ipfs_success,ipfs_ttfb_s,ipfs_total_s,ipfs_bytes,ipfs_http,
    central_success,central_ttfb_s,central_total_s,central_bytes,central_http,alpha,k

and prints, per (alpha,K) cell and overall, how IPFS content delivery compared
to the single nginx server: median / mean / p95 total-delivery time on each
side (successful fetches only), the IPFS/central ratio, and success rates.
"""

from __future__ import annotations

import argparse
import csv
import glob
import os
import statistics
import sys


def pctl(xs: list[float], q: float) -> float:
    """Nearest-rank percentile (q in [0,1]); xs assumed non-empty."""
    if not xs:
        return float("nan")
    s = sorted(xs)
    if len(s) == 1:
        return s[0]
    idx = min(len(s) - 1, max(0, round(q * (len(s) - 1))))
    return s[idx]


class Cell:
    """Aggregates one (alpha, K) operating point."""

    def __init__(self, alpha: int, k: int):
        self.alpha = alpha
        self.k = k
        self.ipfs_total: list[float] = []   # successful IPFS deliveries
        self.central_total: list[float] = []  # successful central deliveries
        self.ipfs_ok = 0
        self.central_ok = 0
        self.n = 0                            # total paired rows

    def add(self, row: dict[str, str]) -> None:
        self.n += 1
        # Success = curl exited 0 AND HTTP 200. curl (no -f) exits 0 on a Kubo
        # gateway 504 (its 30s Gateway.RetrievalTimeout), so the success column
        # alone would count timeouts as wins.
        if row["ipfs_success"] == "1" and row.get("ipfs_http", "200") == "200":
            self.ipfs_ok += 1
            self.ipfs_total.append(float(row["ipfs_total_s"]))
        if row["central_success"] == "1" and row.get("central_http", "200") == "200":
            self.central_ok += 1
            self.central_total.append(float(row["central_total_s"]))

    def summary_row(self) -> dict[str, object]:
        def stats(xs: list[float]) -> tuple[float, float, float]:
            if not xs:
                return (float("nan"), float("nan"), float("nan"))
            return (statistics.median(xs), statistics.fmean(xs), pctl(xs, 0.95))

        i_med, i_mean, i_p95 = stats(self.ipfs_total)
        c_med, c_mean, c_p95 = stats(self.central_total)
        ratio = (i_med / c_med) if (self.ipfs_total and self.central_total
                                    and c_med > 0) else float("nan")
        return {
            "alpha": self.alpha,
            "k": self.k,
            "n": self.n,
            "ipfs_succ": round(self.ipfs_ok / self.n, 3) if self.n else float("nan"),
            "central_succ": round(self.central_ok / self.n, 3) if self.n else float("nan"),
            "ipfs_total_med_s": round(i_med, 4),
            "ipfs_total_mean_s": round(i_mean, 4),
            "ipfs_total_p95_s": round(i_p95, 4),
            "central_total_med_s": round(c_med, 4),
            "central_total_mean_s": round(c_mean, 4),
            "central_total_p95_s": round(c_p95, 4),
            "ipfs_over_central_med": round(ratio, 3),
        }


SUMMARY_COLUMNS = [
    "alpha", "k", "n", "ipfs_succ", "central_succ",
    "ipfs_total_med_s", "ipfs_total_mean_s", "ipfs_total_p95_s",
    "central_total_med_s", "central_total_mean_s", "central_total_p95_s",
    "ipfs_over_central_med",
]

REQUIRED = {
    "trial", "ipfs_success", "ipfs_total_s", "central_success",
    "central_total_s", "alpha", "k",
}


def load(paths: list[str]) -> tuple[dict[tuple[int, int], Cell], int, int]:
    cells: dict[tuple[int, int], Cell] = {}
    total = 0
    skipped = 0
    for p in paths:
        with open(p, newline="") as fh:
            reader = csv.DictReader(fh)
            if reader.fieldnames is None or not REQUIRED.issubset(reader.fieldnames):
                print(f"warning: {p} missing expected columns; skipping file",
                      file=sys.stderr)
                continue
            for row in reader:
                try:
                    key = (int(row["alpha"]), int(row["k"]))
                    # touch the numeric fields so a malformed row is caught here
                    float(row["ipfs_total_s"])
                    float(row["central_total_s"])
                except (ValueError, KeyError, TypeError):
                    skipped += 1
                    continue
                cells.setdefault(key, Cell(*key)).add(row)
                total += 1
    return cells, total, skipped


def print_table(rows: list[dict[str, object]]) -> None:
    hdr = ["alpha", "K", "n", "ipfs_succ", "cen_succ",
           "ipfs_med", "cen_med", "ipfs_p95", "cen_p95", "ipfs/cen"]
    print(f"{hdr[0]:>5} {hdr[1]:>3} {hdr[2]:>4} {hdr[3]:>9} {hdr[4]:>8} "
          f"{hdr[5]:>9} {hdr[6]:>9} {hdr[7]:>9} {hdr[8]:>9} {hdr[9]:>9}")
    print("-" * 84)
    for r in rows:
        print(f"{r['alpha']:>5} {r['k']:>3} {r['n']:>4} "
              f"{r['ipfs_succ']:>9} {r['central_succ']:>8} "
              f"{r['ipfs_total_med_s']:>9} {r['central_total_med_s']:>9} "
              f"{r['ipfs_total_p95_s']:>9} {r['central_total_p95_s']:>9} "
              f"{r['ipfs_over_central_med']:>9}")


def expand_inputs(inputs: list[str]) -> list[str]:
    paths: list[str] = []
    for item in inputs:
        if os.path.isdir(item):
            paths.extend(sorted(glob.glob(os.path.join(item, "*.csv"))))
        elif any(ch in item for ch in "*?["):
            paths.extend(sorted(glob.glob(item)))
        else:
            paths.append(item)
    seen, out = set(), []
    for p in paths:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+",
                    help="baseline CSV files, a directory (globs *.csv), or a glob")
    ap.add_argument("--out-summary", default="baseline_summary.csv",
                    help="path for the aggregated summary CSV "
                         "(default: baseline_summary.csv)")
    args = ap.parse_args(argv)

    paths = expand_inputs(args.inputs)
    if not paths:
        print("error: no input CSV files matched", file=sys.stderr)
        return 2
    missing = [p for p in paths if not os.path.isfile(p)]
    if missing:
        print(f"error: file(s) not found: {missing}", file=sys.stderr)
        return 2

    cells, total, skipped = load(paths)
    if not cells:
        print("error: no usable rows parsed", file=sys.stderr)
        return 1

    rows = [cells[key].summary_row()
            for key in sorted(cells, key=lambda t: (t[0], t[1]))]

    print(f"# loaded {total} paired delivery row(s) from {len(paths)} file(s), "
          f"{len(cells)} (alpha,K) cell(s)"
          + (f", skipped {skipped} bad row(s)" if skipped else ""))
    print()
    print_table(rows)
    print("\n(ipfs/cen = median IPFS delivery time / median centralized "
          "delivery time; <1 means IPFS won, >1 means the single server won)")

    with open(args.out_summary, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=SUMMARY_COLUMNS)
        w.writeheader()
        w.writerows(rows)
    print(f"\nwrote summary -> {args.out_summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
