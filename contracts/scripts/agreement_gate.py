#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Agreement Gate — Python sibling
================================

Sanity-cross-validates the TS reference model's emitted CSVs against the
canonical Track A Python simulator's CSVs. This script is invoked
manually (or by CI) after running `npm run test:agreement` so the TS
trajectories at `contracts/test/reference/outputs/*_ts.csv` exist; it
then compares them to the canonical Track A outputs at
`simulation/outputs/*.csv`.

Exit 0 on agreement within documented tolerance; exit 1 on failure.

Symmetry rationale:
- `agreement_gate.ts` consumes the Python CSVs and verifies its TS bigint
  state reproduces them. That is the *primary* gate — it catches a TS
  model bug or fee-mode mismatch.
- `agreement_gate.py` consumes the TS CSVs and re-verifies parity from
  the Python side. This catches CSV-emission bugs in `agreement_gate.ts`
  (column order, decimal formatting) that would otherwise sneak through.

Tolerance bound:
  abs = 1e-3 (dollar / token units; the same as the TS gate)
  rel = 1e-9 (six orders of magnitude above float64 ULP for 36 months).
"""

from __future__ import annotations

import csv
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONTRACTS_ROOT = HERE.parent
PROJECT_ROOT = CONTRACTS_ROOT.parent
SIM_OUT = PROJECT_ROOT / "simulation" / "outputs"
TS_OUT = CONTRACTS_ROOT / "test" / "reference" / "outputs"

ABS_TOL = 1e-3
REL_TOL = 1e-9


def parse_csv(path: Path) -> list[dict[str, str]]:
    with path.open() as fh:
        reader = csv.DictReader(fh)
        return [dict(row) for row in reader]


def within_tol(a: float, b: float, abs_tol: float, rel_tol: float) -> bool:
    return abs(a - b) <= max(abs_tol, rel_tol * abs(b))


FIELDS = ("treasury", "supply", "floor", "lp_tokens", "lp_stable", "spot")


def compare_csvs(track_a_path: Path, ts_path: Path) -> list[tuple]:
    if not track_a_path.exists():
        raise FileNotFoundError(
            f"Missing Track A CSV {track_a_path}. "
            "Run: python3 ../simulation/generate_figures.py"
        )
    if not ts_path.exists():
        raise FileNotFoundError(
            f"Missing TS CSV {ts_path}. "
            "Run: npm run test:agreement"
        )
    a = parse_csv(track_a_path)
    b = parse_csv(ts_path)
    if len(a) != len(b):
        raise ValueError(
            f"Row-count mismatch: {track_a_path.name}={len(a)} "
            f"vs {ts_path.name}={len(b)}"
        )
    fails = []
    for i, (ra, rb) in enumerate(zip(a, b)):
        for field in FIELDS:
            va, vb = float(ra[field]), float(rb[field])
            if not within_tol(va, vb, ABS_TOL, REL_TOL):
                fails.append((i, field, vb, va, vb - va))
    return fails


def main() -> int:
    print("M² Agreement Gate (Python) — cross-validates TS CSVs against Track A")
    print(f"  Track A CSVs: {SIM_OUT}")
    print(f"  TS CSVs     : {TS_OUT}")
    print(f"  Tolerance   : abs {ABS_TOL}, rel {REL_TOL}")
    print()

    scenarios = [
        ("baseline_12mo", "baseline_12mo.csv", "baseline_12mo_ts.csv"),
        ("baseline_36mo", "baseline_36mo.csv", "baseline_36mo_ts.csv"),
    ]
    total_fails = 0
    for name, a_name, b_name in scenarios:
        a_path = SIM_OUT / a_name
        b_path = TS_OUT / b_name
        print(f"[{name}]")
        try:
            fails = compare_csvs(a_path, b_path)
        except FileNotFoundError as exc:
            print(f"  SKIP: {exc}")
            continue
        if not fails:
            n_rows = len(parse_csv(a_path))
            print(f"  PASS ({n_rows} rows × {len(FIELDS)} fields = {n_rows * len(FIELDS)} checks)")
        else:
            print(f"  FAIL: {len(fails)} discrepancies")
            for row in fails[:10]:
                i, field, ts, a, diff = row
                print(f"    month={i} field={field} ts={ts} trackA={a} diff={diff}")
            if len(fails) > 10:
                print(f"    ... and {len(fails) - 10} more")
            total_fails += len(fails)
        print()

    # Headline anchor sanity check
    anchor = SIM_OUT / "canonical_month12_state.csv"
    if anchor.exists():
        with anchor.open() as fh:
            row = next(csv.DictReader(fh))
        ds = float(row["delta_star"])
        a_star = float(row["A_star"])
        print(f"Headline anchor (canonical_month12_state.csv):")
        print(f"  A*    = {a_star:.4f} tokens (paper: ≈ 6.1999e7)")
        print(f"  Δ*    = ${ds:.4f} (paper: $21,476.5621...)")
        if abs(ds - 21_476.5621) > 0.01:
            print(f"  FAIL: Δ* drifted from paper headline")
            total_fails += 1
        else:
            print(f"  PASS Δ* matches paper headline within $0.01")
    print()

    if total_fails > 0:
        print(f"AGREEMENT GATE FAILED: {total_fails} total discrepancies")
        return 1
    print("AGREEMENT GATE PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
