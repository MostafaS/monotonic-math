#!/usr/bin/env python3
"""
M^2 Paper Figure Generator
==========================
Generates Figures 2-8 in Section 6 of the paper from the closed-form math
of Section 5. The figures use the deterministic recurrence under fee-free
curve math (the design memorandum's baseline projection convention) except
for Figure 8 (Monte Carlo bands), which adds stochastic revenue arrivals.

Canonical genesis state:
    T_0  = $1,000,000        (treasury seed)
    S_0  = 1,000,000,000     (token supply)
    L_t0 = 750,000,000       (LP token reserves, 75% of supply)
    L_s0 = $750,000          (LP stable reserves)
    F_0  = T_0/S_0  = $0.001 per token
    P_0  = L_s0/L_t0 = $0.001 (genesis constraint forces floor = spot)
    k    = L_t0 * L_s0 = 5.625e14

Baseline deterministic recurrence (under fee-free curve math):
    Each month, revenue R = $100k routes 50/50:
      $50k to treasury (T += 50k)
      $50k to LP buy-and-burn:
        L_s(n+1) = L_s(n) + B,  where B = R/2 = $50k
        L_t(n+1) = k / L_s(n+1)            (constant-product preserved)
        Y(n+1)   = L_t(n) - L_t(n+1)       (tokens received and burned)
        S(n+1)   = S(n) - Y(n+1)
        T(n+1)   = T(n) + B
        F(n+1)   = T(n+1) / S(n+1)
        P(n+1)   = L_s(n+1) / L_t(n+1)

All figures saved as PDF (for the paper) and PNG (for preview) in
/Users/mostafa/Documents/Personal_Projects/M2/paper/figures/.
"""

from __future__ import annotations

import os
import csv
from decimal import Decimal, getcontext
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.colors import LogNorm
from pathlib import Path

# ---- Output directories ----------------------------------------------------
HERE = Path(__file__).resolve().parent
FIG_DIR = (HERE.parent / "paper" / "figures").resolve()
FIG_DIR.mkdir(parents=True, exist_ok=True)

# CSV outputs consumed by the contracts repo's agreement gate
# (contracts/scripts/agreement_gate.{ts,py}). Track A is the single source of
# truth; the contracts repo never duplicates the simulator (see FINAL_REPORT
# blocker B2).
OUT_DIR = (HERE / "outputs").resolve()
OUT_DIR.mkdir(parents=True, exist_ok=True)

# ---- Academic clean style --------------------------------------------------
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["DejaVu Serif", "STIX", "Computer Modern Roman"],
    "mathtext.fontset": "dejavuserif",
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.linewidth": 0.8,
    "xtick.major.width": 0.8,
    "ytick.major.width": 0.8,
    "xtick.major.size": 3.5,
    "ytick.major.size": 3.5,
    "axes.grid": True,
    "grid.linestyle": ":",
    "grid.linewidth": 0.5,
    "grid.alpha": 0.6,
    "legend.frameon": False,
    "axes.labelsize": 10,
    "axes.titlesize": 11,
    "legend.fontsize": 9,
    "xtick.labelsize": 9,
    "ytick.labelsize": 9,
    "figure.dpi": 110,
    "savefig.dpi": 300,
    "savefig.bbox": "tight",
})

# Canonical genesis state
T0  = 1_000_000.0
S0  = 1_000_000_000.0
LT0 = 750_000_000.0
LS0 = 750_000.0
K   = LT0 * LS0  # 5.625e14
F0  = T0 / S0    # 0.001
FB  = 0.001      # buy fee (fee-free baseline ignores)
FS  = 0.03       # sell fee

# ---- Core deterministic recurrence (fee-free) ------------------------------

def deterministic_path(
    R_per_month: float, n_months: int,
    T_init: float = T0, S_init: float = S0,
    Lt_init: float = LT0, Ls_init: float = LS0,
    revenue_split_treasury: float = 0.5,
):
    """
    Run the fee-free deterministic recurrence for n_months months.
    Half of monthly revenue goes to treasury; half buys-and-burns tokens.
    Returns dict of arrays with length (n_months+1).
    """
    k = Lt_init * Ls_init
    T = np.zeros(n_months + 1)
    S = np.zeros(n_months + 1)
    Lt = np.zeros(n_months + 1)
    Ls = np.zeros(n_months + 1)
    T[0], S[0], Lt[0], Ls[0] = T_init, S_init, Lt_init, Ls_init

    rho_T = revenue_split_treasury
    for n in range(n_months):
        # treasury deposit
        T[n+1] = T[n] + rho_T * R_per_month
        # buy-and-burn into the LP
        B = (1.0 - rho_T) * R_per_month
        Ls[n+1] = Ls[n] + B
        Lt[n+1] = k / Ls[n+1]
        Y = Lt[n] - Lt[n+1]
        S[n+1] = S[n] - Y

    F = T / S
    P = Ls / Lt
    return dict(T=T, S=S, Lt=Lt, Ls=Ls, F=F, P=P)


# ---- Figure 2: Floor trajectory --------------------------------------------

def fig_floor_trajectory():
    n_months = 36
    R = 100_000.0  # $100k/month
    path = deterministic_path(R, n_months)

    fig, ax = plt.subplots(figsize=(6.4, 4.0))
    months = np.arange(n_months + 1)

    # Floor + spot (left axis, log scale)
    l1, = ax.plot(months, path["F"], color="#1f4d99", lw=2.0,
                  label="Floor $F=T/S$")
    l2, = ax.plot(months, path["P"], color="#b8362c", lw=1.6, linestyle="--",
                  label="Spot $P=L_s/L_t$")
    ax.set_yscale("log")
    ax.set_xlabel("Month")
    ax.set_ylabel("Price per token (USD, log scale)")
    ax.set_xlim(0, n_months)

    # LP half-life vertical guide
    n_half = LS0 / (R / 2.0)  # = 15
    ax.axvline(n_half, color="0.4", lw=0.8, linestyle=":")
    ax.text(n_half + 0.4, ax.get_ylim()[0] * 1.6,
            r"LP half-life $n_{1/2}=15$", fontsize=8, color="0.3",
            ha="left", va="bottom")

    # Supply on right axis
    ax2 = ax.twinx()
    ax2.spines["right"].set_visible(True)
    l3, = ax2.plot(months, path["S"] / 1e9, color="#2f7a37", lw=1.2,
                   linestyle=":", label="Supply $S$ (right axis)")
    ax2.set_ylabel("Supply (billions of tokens)")
    ax2.grid(False)
    ax2.set_ylim(0, 1.05)

    # Legend combined
    lines = [l1, l2, l3]
    ax.legend(lines, [ln.get_label() for ln in lines],
              loc="upper left", fontsize=9)

    ax.set_title("Floor and spot trajectories, baseline S1 (\\$100k/mo., fee-free curve math)")
    out = FIG_DIR / "fig-floor-trajectory"
    fig.savefig(str(out) + ".pdf")
    fig.savefig(str(out) + ".png", dpi=300)
    plt.close(fig)
    return path


# ---- Figure 3: Revenue sweep -----------------------------------------------

def fig_revenue_sweep():
    Rs = np.array([25_000.0, 50_000.0, 100_000.0,
                   250_000.0, 500_000.0, 1_000_000.0])
    F36 = []
    n_half = []
    for R in Rs:
        path = deterministic_path(R, 36)
        F36.append(path["F"][-1])
        n_half.append(2 * LS0 / R)  # = L_{s,0}/(R/2)
    F36 = np.array(F36)
    n_half = np.array(n_half)

    fig, ax = plt.subplots(figsize=(6.4, 4.0))

    l1, = ax.plot(Rs, F36, marker="o", color="#1f4d99", lw=1.6,
                  ms=6, label="Floor at month 36")
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Monthly revenue $R$ (USD, log scale)")
    ax.set_ylabel("Floor $F$ at month 36 (USD/token, log scale)")
    ax.set_xticks(Rs)
    ax.set_xticklabels([f"\\${int(r/1000)}k" if r < 1e6 else "\\$1M" for r in Rs])

    ax2 = ax.twinx()
    ax2.spines["right"].set_visible(True)
    l2, = ax2.plot(Rs, n_half, marker="s", color="#b8362c", lw=1.2,
                   linestyle="--", ms=5,
                   label=r"LP half-life $n_{1/2}(R)=2L_{s,0}/R$")
    ax2.set_xscale("log")
    ax2.set_yscale("log")
    ax2.set_ylabel("LP half-life $n_{1/2}$ (months, log scale)")
    ax2.grid(False)

    lines = [l1, l2]
    ax.legend(lines, [ln.get_label() for ln in lines],
              loc="upper left", fontsize=9)

    ax.set_title("Revenue sweep: month-36 floor and LP half-life vs. revenue rate")
    out = FIG_DIR / "fig-revenue-sweep"
    fig.savefig(str(out) + ".pdf")
    fig.savefig(str(out) + ".png", dpi=300)
    plt.close(fig)


# ---- Figure 4: Pareto LP frontier ------------------------------------------

def fig_lp_frontier():
    rhos = np.array([0.50, 0.60, 0.75, 0.85, 0.90])
    R = 100_000.0
    n_half = []
    F36 = []
    for rho in rhos:
        # Re-seed LP with rho * S0 tokens, keep treasury floor-spot constraint
        # F_0 = T_0/S_0 = L_{s,0}/L_{t,0}.
        # If we fix S_0=1e9 and F_0=$0.001, then T_0 = $1M.
        # With L_{t,0} = rho * S_0, L_{s,0} = F_0 * L_{t,0} = $0.001 * rho * 1e9 = rho * $1M.
        Lt_seed = rho * S0
        Ls_seed = F0 * Lt_seed
        path = deterministic_path(R, 36,
                                  T_init=T0, S_init=S0,
                                  Lt_init=Lt_seed, Ls_init=Ls_seed)
        n_half.append(Ls_seed / (R / 2.0))
        F36.append(path["F"][-1])
    n_half = np.array(n_half)
    F36 = np.array(F36)

    fig, ax = plt.subplots(figsize=(6.4, 4.0))
    ax.plot(n_half, F36, color="0.5", lw=1.0, zorder=1)
    for rho, x, y in zip(rhos, n_half, F36):
        c = "#b8362c" if abs(rho - 0.75) < 1e-9 else "#1f4d99"
        marker = "*" if abs(rho - 0.75) < 1e-9 else "o"
        ms = 14 if abs(rho - 0.75) < 1e-9 else 7
        ax.scatter([x], [y], marker=marker, s=ms*ms, color=c, zorder=3,
                   edgecolor="white", linewidths=0.8)
        ax.annotate(rf"$\rho_{{LP}}={int(rho*100)}\%$",
                    xy=(x, y), xytext=(6, 6), textcoords="offset points",
                    fontsize=8.5,
                    color=c)

    ax.set_xlabel(r"LP half-life $n_{1/2}$ (months)")
    ax.set_ylabel("Floor at month 36 (USD/token)")
    ax.set_title("Pareto frontier: LP longevity vs. floor compounding (\\$100k/mo.)")
    ax.text(0.98, 0.05,
            r"Canonical: $\rho_{LP}=75\%$ (red star)",
            transform=ax.transAxes, ha="right", va="bottom",
            fontsize=8.5, color="#b8362c")
    out = FIG_DIR / "fig-lp-frontier"
    fig.savefig(str(out) + ".pdf")
    fig.savefig(str(out) + ".png", dpi=300)
    plt.close(fig)


# ---- Figure 5: Fee attribution stacked bars --------------------------------

def fig_fee_attribution():
    """
    Single-month attribution of floor growth by source, across f_s values.
    Three sources (all under organic sell volume V = $200k/month at the
    canonical month-12 state):
      (a) treasury deposit         = $50k/mo  (constant in f_s)
      (b) buy-and-burn token burn  = $50k-equivalent in floor terms (constant)
      (c) sell-fee burn from organic volume:
              token amount burned ~= f_s * V / spot
              floor contribution  ~= (tokens_burned / S) * F  in growth-rate terms
    We report the components in dollars-of-floor-growth-per-month for the
    purpose of visualization.
    """
    fs_grid = np.array([0.0, 0.01, 0.03, 0.05, 0.10])
    V = 200_000.0  # organic sell volume per month
    # canonical month-12 state for the attribution calc
    T12 = 1_600_000.0
    S12 = 2e9 / 3       # ~6.667e8
    F12 = T12 / S12     # 0.0024
    Lt12 = 1.25e9 / 3   # ~4.167e8
    Ls12 = 1_350_000.0
    P12 = Ls12 / Lt12

    # In dollars-of-floor-growth-per-month (i.e. d(F * S_constant) ~= dT)
    # Treasury deposit: $50k/mo contributes $50k to T -> floor growth = 50k/S
    # but in dollar-of-treasury terms it's a constant $50k.
    treasury_dep = np.full_like(fs_grid, 50_000.0)
    # Buy-and-burn: reduces S, equivalent value of $50k.  We attribute its
    # floor-equivalent dollar contribution at the canonical state as $50k (the
    # equivalent NPV in T-units), then split-as-equivalent-floor effect.
    buy_burn = np.full_like(fs_grid, 50_000.0)
    # Sell-fee burn: f_s * V dollars of tokens are taken on input; at next
    # collectFees, 99.75% of these tokens are burned.  Dollar value of those
    # tokens at the current spot P12 = $0.003... but conservatively at the
    # FLOOR price F12 = $0.0024 they are worth f_s * V * (F12/P12) dollars.
    # The floor-growth value of burning Y tokens at constant T is approximately
    # T * Y / (S*(S-Y))  per token.  Aggregating to dollar terms,
    # equivalent treasury-units value = (Y * F) ~ floor-equivalent.
    # We render this in dollars-of-treasury-equivalent for stacking:
    Y_per_month = fs_grid * V / P12  # tokens burned/mo from sell-fee channel
    sell_fee_dollars = Y_per_month * F12 * 0.9975  # bounty leak 0.25%
    # (Buy-side 0.10% fee on $50k buy-and-burn rolls into Phi_s; its sell-fee
    # analogue is below the rounding floor for this chart's purposes.)

    fig, ax = plt.subplots(figsize=(7.0, 4.4))
    width = 0.55
    x = np.arange(len(fs_grid))
    p1 = ax.bar(x, treasury_dep, width, label="Treasury deposit (50/50 router)",
                color="#1f4d99")
    p2 = ax.bar(x, buy_burn, width, bottom=treasury_dep,
                label="Buy-and-burn (50/50 router)", color="#5a9bd4")
    p3 = ax.bar(x, sell_fee_dollars, width,
                bottom=treasury_dep + buy_burn,
                label=r"Sell-fee burn ($V=\$200$k/mo organic)", color="#b8362c")

    ax.set_xticks(x)
    ax.set_xticklabels([f"{int(fs*100)}%" if fs > 0 else "0%"
                        for fs in fs_grid])
    ax.set_xlabel("Sell-side fee $f_s$")
    ax.set_ylabel("Monthly floor growth (treasury-equivalent USD)")
    ax.set_title("Fee attribution: monthly floor growth by source across $f_s$ (canonical state)")

    # annotate share, positioned with explicit padding above each bar
    totals = treasury_dep + buy_burn + sell_fee_dollars
    ymax = float(totals.max())
    ax.set_ylim(0, ymax * 1.32)  # leave headroom for labels + legend
    label_pad = ymax * 0.025
    for i, (xi, t) in enumerate(zip(x, totals)):
        share = sell_fee_dollars[i] / t * 100.0
        if share >= 0.5:  # show only non-trivial shares
            ax.text(xi, t + label_pad, f"sell-fee: {share:.1f}%",
                    ha="center", va="bottom", fontsize=8, color="#b8362c")

    # Legend below the plot, outside the data area
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.14),
              ncol=3, fontsize=8.5, frameon=False)
    plt.subplots_adjust(bottom=0.20)

    out = FIG_DIR / "fig-fee-attribution"
    fig.savefig(str(out) + ".pdf")
    fig.savefig(str(out) + ".png", dpi=300)
    plt.close(fig)


# ---- Figure 6: Attacker phase diagram --------------------------------------

def fig_attacker_phasediagram():
    """
    Heatmap of Pi*(alpha, N)/N at canonical month-12 state.
    Pi(alpha, N) = L_s - k/(L_t + (1-f_s)*alpha*N) + (1-alpha)*N*F
    """
    T12 = 1_600_000.0
    S12 = 2e9 / 3
    F12 = T12 / S12
    Lt12 = 1.25e9 / 3
    Ls12 = 1_350_000.0
    k12 = Lt12 * Ls12

    alphas = np.linspace(0.001, 1.0, 220)
    Ns = np.logspace(6, 9, 220)   # 1e6 to 1e9 tokens
    A, N = np.meshgrid(alphas, Ns)

    Pi = (Ls12
          - k12 / (Lt12 + (1 - FS) * A * N)
          + (1 - A) * N * F12)
    PiPerToken = Pi / N

    # Saturation locus: alpha = A_star / N where A_star is state-only
    A_star = (np.sqrt(k12 * (1 - FS) / F12) - Lt12) / (1 - FS)
    sat_alpha = A_star / Ns  # may be >1 for small Ns (regime 1 boundary)
    valid = sat_alpha <= 1.0

    fig, ax = plt.subplots(figsize=(6.4, 4.4))
    pcm = ax.pcolormesh(alphas, Ns, PiPerToken, shading="auto",
                        cmap="viridis")
    ax.set_yscale("log")
    ax.set_xlabel(r"Strategy mix $\alpha$ (fraction dumped to LP)")
    ax.set_ylabel(r"Attacker holdings $N$ (tokens, log scale)")
    cbar = fig.colorbar(pcm, ax=ax, pad=0.02)
    cbar.set_label(r"$\Pi(\alpha,N)/N$ (USD per token)")

    # Saturation curve
    ax.plot(sat_alpha[valid], Ns[valid], color="white", lw=1.6,
            linestyle="--", label=r"Saturation $\alpha N=A^*$")

    # Floor reference line (color limit)
    ax.axvline(0.0, color="white", lw=0.7, linestyle=":", alpha=0.6)

    # A^* horizontal marker
    ax.axhline(A_star, color="white", lw=0.7, linestyle=":", alpha=0.6)
    ax.text(0.02, A_star * 1.1, f"$A^*\\approx 6.20\\times 10^7$",
            color="white", fontsize=8, va="bottom")

    ax.legend(loc="lower right", fontsize=8.5,
              labelcolor="white", facecolor="black", framealpha=0.5)
    ax.set_title("Attacker phase diagram: per-token yield $\\Pi/N$ at canonical month-12 state")
    out = FIG_DIR / "fig-attacker-phasediagram"
    fig.savefig(str(out) + ".pdf")
    fig.savefig(str(out) + ".png", dpi=300)
    plt.close(fig)


# ---- Figure 7: Organic volume sweep ----------------------------------------

def fig_organic_volume():
    """
    Per-month treasury-equivalent floor growth as a function of organic sell
    volume V, decomposed into three stacked components.
    """
    Vs = np.array([10_000.0, 50_000.0, 200_000.0, 500_000.0, 1_000_000.0])
    # canonical month-12 state
    T12 = 1_600_000.0
    S12 = 2e9 / 3
    F12 = T12 / S12
    Lt12 = 1.25e9 / 3
    Ls12 = 1_350_000.0
    P12 = Ls12 / Lt12
    fs = 0.03

    treasury_dep = np.full_like(Vs, 50_000.0)
    buy_burn = np.full_like(Vs, 50_000.0)
    Y_per_month = fs * Vs / P12
    sell_fee_dollars = Y_per_month * F12 * 0.9975

    fig, ax = plt.subplots(figsize=(7.0, 4.4))
    width = 0.55
    x = np.arange(len(Vs))
    ax.bar(x, treasury_dep, width, label="Treasury deposit", color="#1f4d99")
    ax.bar(x, buy_burn, width, bottom=treasury_dep,
           label="Buy-and-burn", color="#5a9bd4")
    ax.bar(x, sell_fee_dollars, width,
           bottom=treasury_dep + buy_burn,
           label=r"Sell-fee burn ($f_s=3\%$)", color="#b8362c")

    ax.set_xticks(x)
    ax.set_xticklabels([f"\\${int(v/1000)}k" if v < 1e6 else "\\$1M"
                        for v in Vs])
    ax.set_xlabel("Organic sell volume $V$ (USD/month)")
    ax.set_ylabel("Monthly floor growth (treasury-equivalent USD)")
    ax.set_title("Floor growth by source vs. organic sell volume (canonical state)")

    totals = treasury_dep + buy_burn + sell_fee_dollars
    ymax = float(totals.max())
    ax.set_ylim(0, ymax * 1.32)  # headroom for labels + legend below
    label_pad = ymax * 0.025
    for i, (xi, t) in enumerate(zip(x, totals)):
        share = sell_fee_dollars[i] / t * 100.0
        if share >= 0.5:  # non-trivial shares only
            ax.text(xi, t + label_pad, f"sell-fee: {share:.1f}%",
                    ha="center", va="bottom", fontsize=8, color="#b8362c")

    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.14),
              ncol=3, fontsize=8.5, frameon=False)
    plt.subplots_adjust(bottom=0.20)

    out = FIG_DIR / "fig-organic-volume"
    fig.savefig(str(out) + ".pdf")
    fig.savefig(str(out) + ".png", dpi=300)
    plt.close(fig)


# ---- Figure 8: Monte Carlo bands -------------------------------------------

def fig_montecarlo_bands():
    """
    Stochastic revenue path: lognormal(sigma_X=1.0) sizes, lambda=1/month
    arrival rate, mu calibrated to E[monthly revenue] = $100k.
    The floor recurrence is deterministic given the realized revenue path;
    we propagate uncertainty by sampling 10,000 monthly revenue paths.
    """
    rng = np.random.default_rng(42)
    n_paths = 10_000
    n_months = 36

    # Calibrate lognormal: for lambda=1 (one arrival per month, simplification),
    # X ~ Lognormal(mu, sigma_X); E[X] = exp(mu + sigma_X^2/2) = 100,000.
    sigma_X = 1.0
    EX = 100_000.0
    mu = np.log(EX) - sigma_X**2 / 2.0
    R_paths = rng.lognormal(mean=mu, sigma=sigma_X, size=(n_paths, n_months))

    # propagate the deterministic recurrence per path
    T  = np.full(n_paths, T0)
    S  = np.full(n_paths, S0)
    Lt = np.full(n_paths, LT0)
    Ls = np.full(n_paths, LS0)
    F_paths = np.zeros((n_paths, n_months + 1))
    F_paths[:, 0] = T / S

    for m in range(n_months):
        R = R_paths[:, m]
        B = 0.5 * R
        T = T + 0.5 * R
        Ls = Ls + B
        Lt_new = K / Ls
        Y = Lt - Lt_new
        S = S - Y
        Lt = Lt_new
        F_paths[:, m + 1] = T / S

    q05 = np.quantile(F_paths, 0.05, axis=0)
    q50 = np.quantile(F_paths, 0.50, axis=0)
    q95 = np.quantile(F_paths, 0.95, axis=0)

    # also deterministic baseline for reference
    detpath = deterministic_path(EX, n_months)

    months = np.arange(n_months + 1)
    fig, ax = plt.subplots(figsize=(6.4, 4.0))
    ax.fill_between(months, q05, q95, color="#1f4d99", alpha=0.18,
                    label="5/95 quantile band")
    ax.plot(months, q50, color="#1f4d99", lw=1.6, label="Median (50%)")
    ax.plot(months, detpath["F"], color="#b8362c", lw=1.2, linestyle="--",
            label=r"Deterministic baseline ($E[R]=\$100$k/mo)")

    ax.set_yscale("log")
    ax.set_xlabel("Month")
    ax.set_ylabel("Floor $F$ (USD/token, log scale)")
    ax.set_xlim(0, n_months)
    ax.legend(loc="lower right", fontsize=9)
    ax.set_title("Monte Carlo floor bands: 10,000 paths, lognormal revenue $\\sigma_X=1.0$")
    out = FIG_DIR / "fig-montecarlo-bands"
    fig.savefig(str(out) + ".pdf")
    fig.savefig(str(out) + ".png", dpi=300)
    plt.close(fig)


# ---- CSV emitters (Phase 1 agreement-gate inputs) --------------------------
#
# These CSVs are consumed by the contracts repo's TS reference model and
# Python sibling at:
#   contracts/scripts/agreement_gate.ts
#   contracts/scripts/agreement_gate.py
# and by the reference-model unit tests in
#   contracts/test/reference/M2ReferenceModel.test.ts
#
# All trajectories are computed under "fee-free curve math" — the paper §6
# Table 1 convention — so the TS reference model must run in its fee-free
# mode for row-by-row comparison. The with-fees mode (the implementation
# convention) is exercised separately by Phase 6 differential tests.

def _write_path_csv(out_path: Path, path: dict, n_months: int) -> None:
    """Write a (T, S, F, Lt, Ls, P) trajectory as one row per month."""
    spot = path["Ls"] / path["Lt"]
    with out_path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["month", "treasury", "supply", "floor",
                    "lp_tokens", "lp_stable", "spot"])
        for m in range(n_months + 1):
            w.writerow([
                m,
                f"{path['T'][m]:.18g}",
                f"{path['S'][m]:.18g}",
                f"{path['F'][m]:.18g}",
                f"{path['Lt'][m]:.18g}",
                f"{path['Ls'][m]:.18g}",
                f"{spot[m]:.18g}",
            ])


def _decimal_sqrt(x: Decimal) -> Decimal:
    """Newton's-method sqrt at the current decimal precision."""
    if x < 0:
        raise ValueError("sqrt of negative")
    if x == 0:
        return Decimal(0)
    # Initial guess via float, then iterate.
    guess = Decimal(float(x).__pow__(0.5))
    # Iterate to convergence at the active precision.
    for _ in range(80):
        nxt = (guess + x / guess) / 2
        if nxt == guess:
            break
        guess = nxt
    return guess


def _emit_canonical_month12_csv(out_path: Path) -> None:
    """
    Compute the Theorem 5.2 anchor (A*, Δ*) at the canonical month-12 state
    using Decimal(prec=60). This is the load-bearing headline number; the TS
    reference model's bigint sqrt is compared against this Decimal-precision
    truth in the unit tests with a documented tolerance.

    Canonical month-12 state (paper §6 Table 1, fee-free curve math):
      T  = 1,600,000
      S  = 2e9 / 3
      F  = T / S = 0.0024  (exact in rationals; 0.0024 ≈ 2.4e-3)
      Lt = 1.25e9 / 3
      Ls = 1,350,000
      k  = Lt * Ls
      A* = (1/(1-f_s)) * (sqrt(k*(1-f_s)/F) - Lt)
      Δ* = Ls - sqrt(k*F/(1-f_s)) - A* * F
    """
    getcontext().prec = 60
    fs = Decimal("0.03")
    T = Decimal(1_600_000)
    S = Decimal(2_000_000_000) / Decimal(3)
    F = T / S  # = 6e6/(2.5e9) = 0.0024 exactly via fraction simplification
    Lt = Decimal(1_250_000_000) / Decimal(3)
    Ls = Decimal(1_350_000)
    k = Lt * Ls
    one_m_fs = Decimal(1) - fs

    sqrt_a = _decimal_sqrt(k * one_m_fs / F)
    A_star = (sqrt_a - Lt) / one_m_fs

    sqrt_b = _decimal_sqrt(k * F / one_m_fs)
    delta_star = Ls - sqrt_b - A_star * F

    with out_path.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["T", "S", "F", "Lt", "Ls", "k", "A_star", "delta_star"])
        # Print with full Decimal precision so the TS test can read them back.
        w.writerow([
            f"{T:f}",
            f"{S:.40f}",
            f"{F:.40f}",
            f"{Lt:.40f}",
            f"{Ls:f}",
            f"{k:.40f}",
            f"{A_star:.40f}",
            f"{delta_star:.40f}",
        ])


def emit_csvs() -> None:
    """Emit Phase 1 agreement-gate CSVs to simulation/outputs/."""
    R = 100_000.0  # paper §6 baseline scenario S1
    path12 = deterministic_path(R, 12)
    path36 = deterministic_path(R, 36)
    _write_path_csv(OUT_DIR / "baseline_12mo.csv", path12, 12)
    _write_path_csv(OUT_DIR / "baseline_36mo.csv", path36, 36)
    _emit_canonical_month12_csv(OUT_DIR / "canonical_month12_state.csv")
    print(f"Writing CSVs to {OUT_DIR}")
    print("  baseline_12mo.csv")
    print("  baseline_36mo.csv")
    print("  canonical_month12_state.csv "
          f"(Δ* via Decimal(prec=60), headline = $21,476.5621...)")


if __name__ == "__main__":
    print(f"Writing figures to {FIG_DIR}")
    path12 = fig_floor_trajectory()
    print(f"  fig-floor-trajectory: F(12) = ${path12['F'][12]:.6f}/token, "
          f"F(36) = ${path12['F'][-1]:.6f}/token")
    fig_revenue_sweep()
    print("  fig-revenue-sweep")
    fig_lp_frontier()
    print("  fig-lp-frontier")
    fig_fee_attribution()
    print("  fig-fee-attribution")
    fig_attacker_phasediagram()
    print("  fig-attacker-phasediagram")
    fig_organic_volume()
    print("  fig-organic-volume")
    fig_montecarlo_bands()
    print("  fig-montecarlo-bands")
    emit_csvs()
    print("Done.")
