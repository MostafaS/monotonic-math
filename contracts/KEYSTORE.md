# Keystore — Required Secrets

The M² Hardhat v3 project resolves all secrets through the Hardhat
keystore. **No `.env` file exists or is permitted.** Every secret named
below is read at config-load time via `configVariable("KEY")` and is
required for the networks / scripts that depend on it.

## Setting a secret

```bash
npx hardhat keystore set KEY_NAME
```

The command prompts for the value; it is encrypted at rest under the
Hardhat keystore (see `~/.config/hardhat-nodejs/keystore`).

## Required keys

| Key | Used by | Notes |
|---|---|---|
| `SEPOLIA_RPC_URL` | `networks.sepolia.url` | HTTPS RPC endpoint for Ethereum Sepolia. Alchemy / Infura / Tenderly all work. |
| `SEPOLIA_PRIVATE_KEY` | `networks.sepolia.accounts` | Deployer key for Sepolia. Fund with Sepolia ETH before running `@sepolia` tests. |
| `MAINNET_RPC_URL` | `networks.hardhatFork.forking.url` | HTTPS RPC endpoint used to fork mainnet for `@fork` tests. Must support `eth_call` at the pinned block. |
| `ETHERSCAN_API_KEY` | `verify.etherscan.apiKey` | Single key works across all chains under Etherscan V2 unified API. |

Optional (added later when scripts demand them):

| Key | Likely usage |
|---|---|
| `MAINNET_PRIVATE_KEY` | Deployer key for production mainnet deployment (Phase 8 / `paper-v1`). |
| `BASE_RPC_URL` | If a second target chain is added per Open Q2. |
| `BASE_PRIVATE_KEY` | Same as above. |

## Commands — set all required keys

```bash
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
npx hardhat keystore set MAINNET_RPC_URL
npx hardhat keystore set ETHERSCAN_API_KEY
```

## Inspecting / removing keys

```bash
npx hardhat keystore list           # lists key names (never values)
npx hardhat keystore get KEY_NAME   # reveals the value to stdout — do not pipe to a logged shell
npx hardhat keystore delete KEY_NAME
```

## Notes

- A key is loaded only when the corresponding network is selected. Running
  `npm run test:local` does NOT require `SEPOLIA_RPC_URL` to be set.
- `MAINNET_RPC_URL` is required for the `hardhatFork` network even when
  no `@fork` test is running, because `hardhat.config.ts` resolves the
  forking URL at config-load time. If you need to compile / run local
  tests on a fresh machine before keys are set, you may temporarily
  comment out the `hardhatFork` network block — but commit nothing.
- The keystore is per-user, not per-project. Two projects on the same
  machine sharing a key name (e.g. `MAINNET_RPC_URL`) will collide.

---

## Phase 7: Sepolia live deployment

This section is the step-by-step procedure to take the Phase 7 deploy
infrastructure (scripts + tests, already in the repo) and execute it
against the real Sepolia network. The dry-run analog
(`npm run dryrun:sepolia`) proves the same path works locally against
an in-memory EDR chain — run it first as a sanity check before
spending real Sepolia ETH.

### Step 1 — Set keystore keys

```bash
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
npx hardhat keystore set ETHERSCAN_API_KEY   # optional, for verification
```

`SEPOLIA_RPC_URL` accepts any HTTPS endpoint (Alchemy / Infura /
Tenderly all work). `SEPOLIA_PRIVATE_KEY` is the deployer EOA's hex key
(without 0x prefix). `ETHERSCAN_API_KEY` is the single Etherscan V2
unified key — one key works across all chains.

### Step 2 — Fund the deployer

Required:

- At least **0.05 Sepolia ETH** for the genesis + e2e txs
  (`scripts/deploy/02_deploy_sepolia.ts` enforces this minimum via a
  pre-flight balance check).

Optional:

- **Circle USDC Sepolia** at
  `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`. The deployer needs
  `T0 + LS0 = 1,000,000 + 750,000 = 1,750,000` USDC units (with 6
  decimals, i.e. `1.75 × 10^12` raw units). Faucet:
  <https://faucet.circle.com>.
- If the deployer does NOT have enough Circle USDC at deploy time, the
  script automatically deploys `MockStable.sol` (mUSD) and uses it as
  the backing stable. This is documented in
  `docs/deployment_runbook.md` ("Sepolia USDC fallback to mUSD").

### Step 3 — Pre-flight dry run (recommended)

```bash
npm run dryrun:sepolia
```

This exercises the SAME deploy + e2e path against a local Hardhat
in-memory EDR chain. If it fails, real Sepolia will fail too. The
dry-run output is written to `deploy/sepolia/dry_run_manifest.json`.

### Step 4 — Deploy to Sepolia (live)

```bash
npm run deploy:sepolia
```

The script:

1. Aborts unless `chainId == 11155111`.
2. Checks deployer ETH balance (>= 0.05 Sepolia ETH).
3. Decides Circle USDC vs MockStable fallback.
4. Deploys `M2GenesisFactory`.
5. Predicts CREATE addresses + mines the hook salt against the live
   factory.
6. Approves the factory for `T0 + LS0` stable.
7. Calls `factory.execute(params)` (single tx; reverts atomically on
   any internal failure).
8. Decodes `GenesisCompleted` from the receipt logs.
9. Writes the deployment manifest to `deploy/sepolia/manifest.json`.

### Step 5 — Run the end-to-end smoke test

```bash
npm run e2e:sepolia
```

The script reads the manifest and exercises the 5 e2e operations
(routeRevenue, lpBuy, lpSell, collectFees, redeem). Each tx hash is
appended to the `e2e` block of `deploy/sepolia/manifest.json`. The
caller wallet must hold a small amount of Sepolia ETH for gas (~0.005
ETH is sufficient).

### Step 6 — Verify on Etherscan (optional)

```bash
npx hardhat verify --network sepolia <token-addr>    <ctor-args>
npx hardhat verify --network sepolia <treasury-addr> <ctor-args>
npx hardhat verify --network sepolia <router-addr>   <ctor-args>
npx hardhat verify --network sepolia <hook-addr>     <ctor-args>
npx hardhat verify --network sepolia <factory-addr>
```

Constructor arguments for each contract are listed in
`docs/deployment_runbook.md`. Etherscan V2 routes via the unified
endpoint; the single `ETHERSCAN_API_KEY` works.

### Step 7 — Run the `@sepolia` integration test

```bash
npm run test:sepolia
```

Reads `deploy/sepolia/manifest.json` and asserts the live deployment's
on-chain state matches expectations (token name/symbol/decimals,
treasury wiring, hook wiring against the Sepolia PoolManager, presence
of e2e tx hashes if `e2e:sepolia` has run).

### Troubleshooting

- If `deploy:sepolia` reverts with "deployer has <X> ETH; need at least
  0.05 ETH": top up the deployer wallet at
  <https://sepoliafaucet.com> or similar.
- If `deploy:sepolia` reverts at `factory.execute()` with an unfamiliar
  custom error, decode it via the manifest's `factory` address using
  Etherscan; the M² error library is at
  `contracts/libraries/M2Errors.sol`.
- If the hook salt mining loop exhausts: the salt is bytecode-dependent;
  re-run `npm run compile` to ensure the artifact matches the current
  source, then retry.
- Re-deploying overwrites `deploy/sepolia/manifest.json`. The old
  contracts on Sepolia remain on-chain — there is no recovery /
  pause / destroy mechanism (paper §3.1).
