# Simulation (Track A)

This folder is **Track A** of the two-track simulator stack described in paper §6.1:

| Track | Substrate | Purpose | Status |
|---|---|---|---|
| **A — Python analytics** (this folder) | NumPy / Matplotlib | Closed-form deterministic recurrence + stochastic-revenue Monte Carlo; produces every figure in paper §6 | **Implemented** — `generate_figures.py` |
| **B — Hardhat v3 invariant tests** (`../contracts/`) | Solidity `.t.sol` (forge-std imports, run by Hardhat v3's EDR) | Asserts the floor-monotonicity, treasury-solvency, supply-cap, and redemption-solvency invariants on the actual compiled bytecode | **Pre-implementation** — lands with the reference contracts |

## Quick start

Requires Python 3.10+.

```bash
cd simulation
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 generate_figures.py
```

Output PDFs and PNGs are written to `../paper/figures/`. The script is deterministic — same seed (`42`) → identical Monte Carlo bands across runs (up to matplotlib font-rendering drift).

## What `generate_figures.py` does

Seven figures, one function each, all driven by the closed-form recurrence of paper §5 (deterministic 50/50 router, fee-free curve math except where noted) plus a single Monte Carlo wrapper for Figure 8:

| Function | Figure | Paper reference |
|---|---|---|
| `fig_floor_trajectory()` | `fig-floor-trajectory.pdf` | Fig. 2 — 36-month floor/spot/supply, LP half-life marked at month 15 |
| `fig_revenue_sweep()` | `fig-revenue-sweep.pdf` | Fig. 3 — month-36 floor vs. monthly revenue (log–log) |
| `fig_lp_frontier()` | `fig-lp-frontier.pdf` | Fig. 4 — Pareto frontier across LP/vesting splits |
| `fig_fee_attribution()` | `fig-fee-attribution.pdf` | Fig. 5 — stacked attribution across `f_s` values |
| `fig_attacker_phasediagram()` | `fig-attacker-phasediagram.pdf` | Fig. 6 — heatmap of Π/N with saturation locus |
| `fig_organic_volume()` | `fig-organic-volume.pdf` | Fig. 7 — stacked attribution across organic-volume regimes |
| `fig_montecarlo_bands()` | `fig-montecarlo-bands.pdf` | Fig. 8 — 10,000-path Monte Carlo, 5/50/95 quantile bands, seed 42 |

All canonical state values (`T = $1.6M`, `S = 666.67M`, `F = $0.0024`, etc.) match Theorem 5.2's numerical illustration in paper §5.2 (`Δ* ≈ $21,476.56`, verified to 60-digit decimal precision).

## What's NOT here (yet)

The following land when the contracts in `../contracts/` are implemented:

1. **Trace-export mode.** A switch to write full state trajectories (`T, S, L_t, L_s, F, P`) per month to CSV, so Track B can diff against them. Easy addition — currently the recurrence runs only as a precursor to figure generation.
2. **Agreement-gate script.** A diff routine comparing Track A's CSVs against Track B's Hardhat-emitted JSON state-diffs. Lives at `../scripts/agreement_gate.py` when written.
3. **Full Monte Carlo against organic-flow processes.** The current MC samples only revenue (lognormal); the full paper-promised version adds geometric Brownian motion on spot, mapped through a constant-elasticity demand curve to per-block buy/sell volume. Adds ~100 lines to `generate_figures.py`.

For the current state of the paper — closed-form figures + a stochastic-revenue Monte Carlo extension — `generate_figures.py` is sufficient on its own.

## Reproducibility

The script is pure Python with two pinned dependencies (see `requirements.txt`). Running it on a fresh venv produces bit-identical PDFs (modulo matplotlib version drift). The git tag `paper-v1` pins the version cited in the paper's abstract.
