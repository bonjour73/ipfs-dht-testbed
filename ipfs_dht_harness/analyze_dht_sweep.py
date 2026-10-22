#!/usr/bin/env python3
"""analyze_dht_sweep.py — analysis for the IPFS alpha/K experiment.

Reads one or more CSV files produced by the `dhtharness` runner (main.go) and
aggregates them per (alpha, K) cell into summary statistics and
(optionally) plots.

Input CSV header (as written by main.go):
    trial,lookup_id,key,latency_ms,peers_heard,peers_queried,
    unreachable,hops,terminate,alpha,k,providers,success

What it reports, per (alpha, K) group:
    n              number of lookup rows
    success_rate   fraction of rows with success == true
    latency_ms     median / mean / p90 / p95 / stdev  (successful rows only)
    peers_queried  mean distinct peers messaged  = message-cost proxy
    peers_heard    mean distinct peers discovered
    hops           mean referral-chain depth
    unreachable    mean peers that failed to answer
    terminate      count breakdown of termination reasons

Usage:
    python3 analyze_dht_sweep.py run_a10_k20.csv run_a20_k40.csv ...
    python3 analyze_dht_sweep.py results/            # globs results/*.csv
    python3 analyze_dht_sweep.py results/ \\
        --out-summary summary.csv \\
        --plots-dir plots \\
        --baseline 10:20
"""

from __future__ import annotations

import argparse
import csv
import glob
import math
import os
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field

EXPECTED_HEADER = [
    "trial", "lookup_id", "key", "latency_ms", "peers_heard",
    "peers_queried", "unreachable", "hops", "terminate", "alpha", "k",
    "providers", "success",
]


# --------------------------------------------------------------------------- #
# Stats helpers (stdlib only)
# --------------------------------------------------------------------------- #
def _percentile(sorted_vals: list[float], q: float) -> float:
    """Linear-interpolation percentile (q in [0,100]) on a pre-sorted list."""
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    rank = (q / 100.0) * (len(sorted_vals) - 1)
    lo = math.floor(rank)
    hi = math.ceil(rank)
    if lo == hi:
        return sorted_vals[int(rank)]
    frac = rank - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def _mean(vals: list[float]) -> float:
    return sum(vals) / len(vals) if vals else float("nan")


def _stdev(vals: list[float]) -> float:
    """Sample standard deviation; nan for <2 points."""
    if len(vals) < 2:
        return float("nan")
    m = _mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / (len(vals) - 1))


def _median(vals: list[float]) -> float:
    return _percentile(sorted(vals), 50.0)


# --------------------------------------------------------------------------- #
# Data model
# --------------------------------------------------------------------------- #
@dataclass
class Cell:
    """All observations for one (alpha, K) parameter combination."""
    alpha: int
    k: int
    n: int = 0
    successes: int = 0
    latency_ok: list[float] = field(default_factory=list)  # successful only
    peers_queried: list[float] = field(default_factory=list)
    peers_heard: list[float] = field(default_factory=list)
    hops: list[float] = field(default_factory=list)
    unreachable: list[float] = field(default_factory=list)
    terminate: Counter = field(default_factory=Counter)

    @property
    def success_rate(self) -> float:
        return self.successes / self.n if self.n else float("nan")

    def summary_row(self) -> dict:
        lat = sorted(self.latency_ok)
        return {
            "alpha": self.alpha,
            "k": self.k,
            "n": self.n,
            "success_rate": round(self.success_rate, 4),
            "lat_median_ms": round(_median(self.latency_ok), 3),
            "lat_mean_ms": round(_mean(self.latency_ok), 3),
            "lat_p90_ms": round(_percentile(lat, 90.0), 3),
            "lat_p95_ms": round(_percentile(lat, 95.0), 3),
            "lat_stdev_ms": round(_stdev(self.latency_ok), 3),
            "peers_queried_mean": round(_mean(self.peers_queried), 2),
            "peers_heard_mean": round(_mean(self.peers_heard), 2),
            "hops_mean": round(_mean(self.hops), 2),
            "unreachable_mean": round(_mean(self.unreachable), 2),
            "terminate": ";".join(f"{k}={v}" for k, v in self.terminate.most_common()),
        }


SUMMARY_COLUMNS = [
    "alpha", "k", "n", "success_rate",
    "lat_median_ms", "lat_mean_ms", "lat_p90_ms", "lat_p95_ms", "lat_stdev_ms",
    "peers_queried_mean", "peers_heard_mean", "hops_mean", "unreachable_mean",
    "terminate",
]


# --------------------------------------------------------------------------- #
# Loading
# --------------------------------------------------------------------------- #
def _to_float(s: str):
    s = (s or "").strip()
    if s == "":
        return None
    try:
        return float(s)
    except ValueError:
        return None


def load_files(paths: list[str]) -> tuple[dict[tuple[int, int], Cell], int, int]:
    """Parse the given CSVs into (alpha,k) cells. Returns (cells, rows, skipped)."""
    cells: dict[tuple[int, int], Cell] = {}
    total_rows = 0
    skipped = 0

    for path in paths:
        with open(path, newline="") as fh:
            reader = csv.DictReader(fh)
            if reader.fieldnames is None:
                continue
            missing = [c for c in ("alpha", "k", "success") if c not in reader.fieldnames]
            if missing:
                print(f"warn: {path} missing columns {missing}; skipping file",
                      file=sys.stderr)
                continue
            for row in reader:
                a = _to_float(row.get("alpha"))
                k = _to_float(row.get("k"))
                if a is None or k is None:
                    skipped += 1
                    continue
                key = (int(a), int(k))
                cell = cells.get(key)
                if cell is None:
                    cell = Cell(alpha=int(a), k=int(k))
                    cells[key] = cell

                total_rows += 1
                cell.n += 1

                success = (row.get("success", "").strip().lower() == "true")
                if success:
                    cell.successes += 1

                lat = _to_float(row.get("latency_ms"))
                if lat is not None and success:
                    cell.latency_ok.append(lat)

                for src, dst in (
                    ("peers_queried", cell.peers_queried),
                    ("peers_heard", cell.peers_heard),
                    ("hops", cell.hops),
                    ("unreachable", cell.unreachable),
                ):
                    v = _to_float(row.get(src))
                    if v is not None:
                        dst.append(v)

                term = (row.get("terminate") or "").strip() or "unknown"
                cell.terminate[term] += 1

    return cells, total_rows, skipped


# --------------------------------------------------------------------------- #
# Output: printed table
# --------------------------------------------------------------------------- #
def print_table(rows: list[dict]) -> None:
    if not rows:
        print("(no data)")
        return
    cols = ["alpha", "k", "n", "success_rate", "lat_median_ms", "lat_p95_ms",
            "peers_queried_mean", "hops_mean", "unreachable_mean"]
    headers = {
        "alpha": "alpha", "k": "K", "n": "n", "success_rate": "succ",
        "lat_median_ms": "lat_med", "lat_p95_ms": "lat_p95",
        "peers_queried_mean": "msg_cost", "hops_mean": "hops",
        "unreachable_mean": "unreach",
    }
    widths = {c: len(headers[c]) for c in cols}
    disp: list[dict] = []
    for r in rows:
        d = {c: ("nan" if isinstance(r[c], float) and math.isnan(r[c]) else str(r[c]))
             for c in cols}
        disp.append(d)
        for c in cols:
            widths[c] = max(widths[c], len(d[c]))
    line = "  ".join(headers[c].rjust(widths[c]) for c in cols)
    print(line)
    print("  ".join("-" * widths[c] for c in cols))
    for d in disp:
        print("  ".join(d[c].rjust(widths[c]) for c in cols))


def print_deltas(rows: list[dict], baseline: tuple[int, int]) -> None:
    """Print latency / message-cost / success deltas vs a baseline (alpha,K) cell."""
    by_key = {(r["alpha"], r["k"]): r for r in rows}
    base = by_key.get(baseline)
    if base is None:
        print(f"\n(baseline alpha={baseline[0]} K={baseline[1]} not present; "
              f"skipping delta table)")
        return

    def pct(new, old):
        if old is None or (isinstance(old, float) and (math.isnan(old) or old == 0)):
            return "n/a"
        return f"{(new - old) / old * 100:+.1f}%"

    print(f"\nDeltas vs baseline alpha={baseline[0]} K={baseline[1]} "
          f"(lat_median={base['lat_median_ms']}ms, "
          f"msg_cost={base['peers_queried_mean']}, "
          f"succ={base['success_rate']}):")
    cols = ["cell", "d_lat_median", "d_msg_cost", "d_success_rate"]
    print("  ".join(c.rjust(14) for c in cols))
    print("  ".join("-" * 14 for _ in cols))
    for r in rows:
        cell = f"a{r['alpha']}/K{r['k']}"
        drow = [
            cell,
            pct(r["lat_median_ms"], base["lat_median_ms"]),
            pct(r["peers_queried_mean"], base["peers_queried_mean"]),
            pct(r["success_rate"], base["success_rate"]),
        ]
        print("  ".join(str(x).rjust(14) for x in drow))


# --------------------------------------------------------------------------- #
# Output: plots (optional, needs matplotlib)
# --------------------------------------------------------------------------- #
def make_plots(cells: dict[tuple[int, int], Cell], out_dir: str) -> bool:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception as e:  # noqa: BLE001
        print(f"note: matplotlib unavailable ({e}); skipping plots.", file=sys.stderr)
        return False

    os.makedirs(out_dir, exist_ok=True)
    ks = sorted({k for (_, k) in cells})

    def series_vs_alpha(metric):
        """metric(cell) -> y ; returns {K: (alphas, ys)} sorted by alpha."""
        out = {}
        for k in ks:
            pts = sorted((a, metric(cells[(a, k)]))
                         for (a, kk) in cells if kk == k)
            pts = [(a, y) for a, y in pts if y is not None and not
                   (isinstance(y, float) and math.isnan(y))]
            if pts:
                out[k] = ([a for a, _ in pts], [y for _, y in pts])
        return out

    panels = [
        ("latency_vs_alpha.png", "median lookup latency (ms)",
         lambda c: _median(c.latency_ok)),
        ("msgcost_vs_alpha.png", "mean peers queried (message cost)",
         lambda c: _mean(c.peers_queried)),
        ("success_vs_alpha.png", "success rate",
         lambda c: c.success_rate),
        ("hops_vs_alpha.png", "mean hops (referral depth)",
         lambda c: _mean(c.hops)),
    ]

    made = 0
    for fname, ylabel, metric in panels:
        data = series_vs_alpha(metric)
        if not data:
            continue
        fig, ax = plt.subplots(figsize=(7, 4.5))
        for k, (xs, ys) in data.items():
            ax.plot(xs, ys, marker="o", label=f"K={k}")
        ax.set_xlabel("alpha (query concurrency)")
        ax.set_ylabel(ylabel)
        ax.set_title(ylabel + " vs alpha")
        ax.grid(True, alpha=0.3)
        if len(data) > 1:
            ax.legend(title="bucket size")
        fig.tight_layout()
        fig.savefig(os.path.join(out_dir, fname), dpi=120)
        plt.close(fig)
        made += 1

    print(f"wrote {made} plot(s) to {out_dir}/", file=sys.stderr)
    return made > 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def expand_inputs(inputs: list[str]) -> list[str]:
    paths: list[str] = []
    for item in inputs:
        if os.path.isdir(item):
            paths.extend(sorted(glob.glob(os.path.join(item, "*.csv"))))
        elif any(ch in item for ch in "*?["):
            paths.extend(sorted(glob.glob(item)))
        else:
            paths.append(item)
    # de-dup, preserve order
    seen, out = set(), []
    for p in paths:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def parse_baseline(s: str | None) -> tuple[int, int] | None:
    if not s:
        return None
    try:
        a, k = s.split(":")
        return (int(a), int(k))
    except Exception:  # noqa: BLE001
        raise argparse.ArgumentTypeError("baseline must look like ALPHA:K, e.g. 10:20")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+",
                    help="CSV files, a directory (globs *.csv), or a glob pattern")
    ap.add_argument("--out-summary", default="dht_sweep_summary.csv",
                    help="path for the aggregated summary CSV "
                         "(default: dht_sweep_summary.csv)")
    ap.add_argument("--plots-dir", default=None,
                    help="if set, write PNG plots here (needs matplotlib)")
    ap.add_argument("--baseline", type=parse_baseline, default="10:20",
                    help="baseline cell ALPHA:K for the delta table "
                         "(default: 10:20 = stock Kademlia)")
    args = ap.parse_args(argv)

    paths = expand_inputs(args.inputs)
    if not paths:
        print("error: no input CSV files matched", file=sys.stderr)
        return 2
    missing = [p for p in paths if not os.path.isfile(p)]
    if missing:
        print(f"error: file(s) not found: {missing}", file=sys.stderr)
        return 2

    cells, total_rows, skipped = load_files(paths)
    if not cells:
        print("error: no usable rows parsed", file=sys.stderr)
        return 1

    rows = [cells[key].summary_row()
            for key in sorted(cells, key=lambda t: (t[0], t[1]))]

    print(f"# loaded {total_rows} lookup rows from {len(paths)} file(s), "
          f"{len(cells)} (alpha,K) cell(s)"
          + (f", skipped {skipped} bad row(s)" if skipped else ""))
    print()
    print_table(rows)

    baseline = args.baseline if isinstance(args.baseline, tuple) else parse_baseline(args.baseline)
    if baseline:
        print_deltas(rows, baseline)

    with open(args.out_summary, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=SUMMARY_COLUMNS)
        w.writeheader()
        w.writerows(rows)
    print(f"\nwrote summary -> {args.out_summary}")

    if args.plots_dir:
        make_plots(cells, args.plots_dir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
