# M² Reproducibility

This document is the single source of truth for reproducing every
numerical claim in the M² paper (`paper/main.pdf`) and every passing
test in the Solidity reference implementation (`contracts/`).

The paper-v1 artifact is pinned at Zenodo DOI
[`10.5281/zenodo.20255141`](https://doi.org/10.5281/zenodo.20255141)
(v0.1.1-paper-v1, 2026-05-17).

---

## Prerequisites

- **Python 3.10+** (3.11 recommended) with `pip`
- **Node.js 22+** (LTS) with `npm` (Hardhat v3 is ESM-only; Node 20+ is
  the minimum, Node 22 is the project standard)
- **Git**
- **8 GB free RAM** for the production-scale invariant suite
  (`make verify-full`). The fast gate (`make verify`) runs comfortably
  in 4 GB.
- **Disk:** ~2 GB after `npm ci` (Hardhat v3 + V4 + OZ).

No `.env` file is needed. All Hardhat secrets live in the Hardhat
keystore — see `contracts/KEYSTORE.md`.

## Clone & install

```bash
git clone https://github.com/<your-org>/M2.git
cd M2

# Track A — Python simulator
cd simulation
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cd ..

# Track B — Solidity reference implementation
cd contracts
npm ci
cd ..
```

## One-command verify (under 5 minutes)

The project-root `Makefile` chains both tracks:

```bash
make verify
```

This runs `make reproduce` (Track A figure regeneration + contracts
compile) followed by `cd contracts && npm run ci` (compile +
`check:pragma` + `check:hook-salt` + lint + audit:bytecode +
audit:inheritance + test:reference + test:agreement + test:local +
test:invariant). Expected wallclock on a 2026 laptop: 3–5 minutes.

## Full pre-tag verify

```bash
make verify-full
```

Adds:

- `test:invariant:full` — the Phase-4 acceptance scale
  (`M2_FUZZ_RUNS=10000`, `M2_INVARIANT_RUNS=100000`,
  `M2_INVARIANT_DEPTH=200`). Wallclock ~25–35 minutes.
- `M2_ENABLE_FORK_TESTS=1 test:fork` — mainnet-fork integration tests
  (`MainnetFork12MonthRouteRevenue.t.sol`,
  `MainnetForkVestingMassDump.t.sol`,
  `Theorem5_2BankRun.t.sol` on `@fork`). Requires a `MAINNET_RPC_URL`
  in the Hardhat keystore:

  ```bash
  cd contracts && npx hardhat keystore set MAINNET_RPC_URL
  ```

Expected total wallclock for `make verify-full`: 30–45 minutes,
depending on RPC latency.

## What gets verified

### Track A — Python simulator (`simulation/`)

`python simulation/generate_figures.py` regenerates every paper figure
and every canonical CSV from the deterministic closed-form recurrence
of paper §5. Outputs:

- `paper/figures/fig-floor-trajectory.pdf` — paper Fig. 2 (§6.2)
- `paper/figures/fig-revenue-sweep.pdf` — paper Fig. 3 (§6.3)
- `paper/figures/fig-lp-frontier.pdf` — paper Fig. 4 (§6.4)
- `paper/figures/fig-fee-attribution.pdf` — paper Fig. 5 (§6.5)
- `paper/figures/fig-attacker-phasediagram.pdf` — paper Fig. 6 (§6.6)
- `paper/figures/fig-organic-volume.pdf` — paper Fig. 7 (§6.6)
- `paper/figures/fig-montecarlo-bands.pdf` — paper Fig. 8 (§6.7;
  seed `42`)
- `simulation/outputs/baseline_12mo.csv` — paper Table 1 (§6.2)
- `simulation/outputs/baseline_36mo.csv` — paper Fig. 2 trajectory
- `simulation/outputs/canonical_month12_state.csv` — Theorem 5.2
  Decimal(60) anchor (`Δ* = $21,476.5621...`)

These regenerate bit-identically up to matplotlib font-rendering drift
on every run.

### Track B — Solidity reference (`contracts/`)

`cd contracts && npm run ci` chains:

- `compile` — Hardhat v3, solc `0.8.34` exact, `viaIR: true`, `cancun`
- `check:pragma` — no caret pragmas under `contracts/` or `test/`
- `check:hook-salt` — V4 hook CREATE2 salt is deterministic vs.
  pinned bytecode
- `lint` — solhint with `avoid-suicide`, `avoid-tx-origin`,
  `avoid-throw`, `no-inline-assembly`, `compiler-version: 0.8.34`
- `audit:bytecode` — no `SELFDESTRUCT`, no `_mint` reachable from any
  external entry point, function-selector enumeration matches the
  paper §4.3 exhaustiveness clause
- `audit:inheritance` — no `Ownable`/`AccessControl`/`Pausable`/
  `UUPSUpgradeable` in any of the four immutable contracts
- `test:reference` — TS reference model parity tests (17 tests;
  Lemma 4.2 residual, Theorem 4.3 monotonicity, Theorem 5.2 closed-form
  vs. Decimal(60) anchor)
- `test:agreement` — Track A CSV ↔ Track B state agreement gate (paper
  §6.1)
- `test:local` — Hardhat in-memory EDR end-to-end
- `test:invariant` — fast gate (1k runs / 1k sequences / depth 50) — the
  production-scale gate is `test:invariant:full` (10k / 100k / 200),
  invoked by `make verify-full`

The full mapping of paper claims to test files is in
`contracts/docs/paper_claim_to_test.md`.

### CI

The same gates run on GitHub Actions on every push and pull request to
`main` via `.github/workflows/ci.yml`. The `paper-v1` tag triggers the
heavy gate (full invariant + mainnet-fork) automatically.

Required CI secrets (set via the GitHub UI under Settings → Secrets and
variables → Actions):

- `MAINNET_RPC_URL` — used by `@fork` tests
- `SEPOLIA_RPC_URL` — used by `@sepolia` deploy / smoke tests
- `SEPOLIA_PRIVATE_KEY` — deployer key for Sepolia
- `ETHERSCAN_API_KEY` — Etherscan V2 unified API key for contract
  verification

## Manual reproduction of the headline claim (Theorem 5.2)

The paper's headline number — `Δ* = $21,476.5621...` at the canonical
month-12 state — can be reproduced in three independent ways:

1. **Closed form** (paper Theorem 5.2):
   ```bash
   python -c "
   from decimal import Decimal, getcontext
   getcontext().prec = 60
   T  = Decimal('1600000')
   S  = Decimal('666666666.666666666666666666')
   Lt = Decimal('416666666.666666666666666666')
   Ls = Decimal('1350000')
   fs = Decimal('0.03')
   F  = T / S
   k  = Lt * Ls
   sqrt_term = (k * F / (Decimal(1) - fs)).sqrt()
   Astar = (((k * (Decimal(1) - fs) / F).sqrt()) - Lt) / (Decimal(1) - fs)
   delta = Ls - sqrt_term - Astar * F
   print(f'Δ* = ${delta:.4f}')
   "
   ```
   Should print `Δ* = $21476.5621` (4-decimal rounded).

2. **Track A simulator anchor**:
   ```bash
   python simulation/generate_figures.py
   # Δ* appears as a column in:
   cat simulation/outputs/canonical_month12_state.csv
   ```

3. **Track B Solidity differential**:
   ```bash
   cd contracts && npm run test:differential
   # Or the @local Solidity closed-form check:
   cd contracts && npm run test:integration  # runs Theorem5_2BankRun.t.sol
   ```

All three paths must agree within the documented V4 tick-rounding
tolerance (≤ 0.5%; empirical band ≤ 0.1 bps).

## Open items for the `paper-v1` tag

The following items require user action and are not automatable by an
agent:

- Set the Hardhat keystore secrets on the deployer machine:
  ```bash
  cd contracts
  npx hardhat keystore set SEPOLIA_RPC_URL
  npx hardhat keystore set SEPOLIA_PRIVATE_KEY
  npx hardhat keystore set MAINNET_RPC_URL
  npx hardhat keystore set ETHERSCAN_API_KEY
  ```
- Configure the same secrets on the GitHub repository (Settings →
  Secrets and variables → Actions).
- Execute the Sepolia live deployment per `contracts/KEYSTORE.md`
  ("Phase 7: Sepolia live deployment") and commit
  `contracts/deploy/sepolia/manifest.json`.
- Tag `paper-v1` (`git tag -s paper-v1 && git push --tags`) to trigger
  the heavy GitHub Actions gate.

## Reproducibility manifest (for paper-v1 archival)

After `make verify-full` completes, the run produces:

- All files under `paper/figures/`
- All files under `simulation/outputs/`
- `contracts/test/invariant/seeds/` (any minimized failing seed, with
  per-seed Markdown notes)
- `contracts/deploy/**/manifest*.json` (Sepolia / mainnet deployment
  manifests)

These artifacts are uploaded to Zenodo at tag time. The Zenodo DOI for
the v0.1.1-paper-v1 deposit is
[`10.5281/zenodo.20255141`](https://doi.org/10.5281/zenodo.20255141);
the concept DOI [`10.5281/zenodo.20255140`](https://doi.org/10.5281/zenodo.20255140)
resolves to the latest version.

## License

MIT — see `LICENSE`. The mechanism is released as a non-proprietary
tokenomics primitive available to any DeFi project.
