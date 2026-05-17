# Deployment Runbook

This document specifies the operational procedure for deploying M² to a
target chain. It covers (a) pre-deployment checks, (b) the single-tx
genesis ceremony, (c) post-deployment operational mitigations (the MEV
mitigations enumerated by paper §3.4 and Theorem 5.6), and (d) the
Sepolia testnet's USDC-vs-mUSD fallback logic.

The four immutable contracts are deployed once; there is no recovery
mechanism for a botched deployment. **Do the dry run first.**

---

## Pre-deployment checklist

For each target chain:

- [ ] Hardhat keystore has `<NETWORK>_RPC_URL`, `<NETWORK>_PRIVATE_KEY`,
      and `ETHERSCAN_API_KEY` set (see `KEYSTORE.md`).
- [ ] Deployer address has sufficient native gas for the single-tx
      genesis ceremony (benchmarked at Phase 5; ≤ block-gas limit of
      the target chain).
- [ ] Deployer address holds the genesis treasury seed `T_0` and the
      LP stable seed `L_{s,0}` in the backing stable (e.g. USDC).
- [ ] Backing stable's `decimals()` is ≤ 18 (constructor reverts
      otherwise). Verified for USDC (6), DAI (18), USDT (6).
- [ ] Genesis floor-spot constraint `T_0 · L_{t,0} == L_{s,0} · S_0`
      pre-computed and matches the deployment script's parameters.
- [ ] V4 PoolManager address for the target chain is known and verified
      (cross-check against Uniswap's official deployment registry).
- [ ] Hook CREATE2 salt has been mined such that the resulting hook
      address satisfies V4's `BEFORE_SWAP_FLAG` permission-flag bits.
      **The mined salt is bytecode-dependent**, so it changes if the
      compiler pin changes (which it must not — solc is pinned to 0.8.34).
- [ ] Vesting recipients enumerated with their `(amount, start, duration)`
      schedules; sum of amounts equals 250M tokens.
- [ ] Vesting recipient count is **bounded by the factory's CREATE-nonce-
      prediction depth (≲ 123)**. The factory's `_predictCreate` helper
      RLP-encodes the nonce using the short form (`0xd6 0x94 <addr>
      <nonce>`), which is only valid for `nonce ∈ [1, 0x7f]`. The factory
      consumes nonces 1–4 for treasury / token / hook / router, leaving
      `0x7f − 4 = 123` slots for vesting wallets. Production deployments
      with more than 123 recipients must batch into multiple vesting
      wallets (one wallet funding several beneficiaries) or use a chain-
      of-wallets pattern. Exceeding the cap reverts the entire genesis
      tx via the `require(nonce >= 1 && nonce <= 0x7f, ...)` guard.
- [ ] Dry-run of `M2GenesisFactory.execute()` on a mainnet fork or
      Sepolia has succeeded end-to-end.

## Target chains

| Chain | Status | PoolManager | Backing stable |
|---|---|---|---|
| Ethereum mainnet | Canonical | (canonical V4 PoolManager address — confirm at Phase 5) | USDC `0xA0b8...eB48` |
| Base | Recommended (cheaper, V4 native) | (Base V4 PoolManager — confirm at Phase 5) | USDC on Base |
| Sepolia | Test only | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` | Circle USDC Sepolia `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (fallback: deployed mUSD) |

Other V4 testnets (documented for reference):

| Chain | Chain ID | PoolManager | USDC |
|---|---|---|---|
| Base Sepolia | 84532 | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| Arbitrum Sepolia | 421614 | `0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317` | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| Unichain Sepolia | 1301 | `0x00b036b58a818b1bc34d502d3fe730db729e62ac` | `0x31d0220469e10c4E71834a79b1f276d740d3768F` |

## Genesis ceremony — single-tx `execute()`

The factory's `execute(GenesisParams)` runs 13 steps atomically and
emits `GenesisCompleted(token, treasury, router, hook, vestingWallets)`.
If any step reverts, the entire transaction reverts and no contracts are
deployed.

1. Precompute CREATE2 addresses for token, treasury, router, hook,
   vesting wallets.
2. Mine / select hook salt satisfying V4 hook permission-flag address
   requirements.
3. Deploy treasury with precomputed token address.
4. Deploy token with treasury, router, hook addresses.
5. Deploy hook with token, stable, treasury, PoolManager.
6. Deploy router with token, stable, treasury, hook / pool references,
   depositor, `minTokensOut` plumbing.
7. Deploy vesting wallet(s).
8. Mint genesis supply `S_0 = 10^9` to factory.
9. Seed treasury with `T_0` stable (pulled from deployer).
10. Initialize V4 pool with `DYNAMIC_FEE_FLAG`; seed full-range LP with
    `L_{t,0} = 7.5 · 10^8` tokens and `L_{s,0}` stable.
11. Transfer vesting allocation (`2.5 · 10^8` tokens) to vesting wallet(s).
12. Verify genesis constraint `T_0 · L_{t,0} == L_{s,0} · S_0`; revert
    with `GenesisConstraintViolated` otherwise.
13. Emit `GenesisCompleted`.

There is NO `finalize()` step. There is NO multi-tx fallback. The
factory has no admin role and is itself non-upgradeable.

## Sepolia USDC fallback to mUSD

Sepolia deployments default to **Circle USDC Sepolia** as the backing
stable. If the deployer's Circle USDC Sepolia balance is empty at
deploy time, the deployment script auto-detects the condition and:

1. Deploys `contracts/mocks/MockStable.sol` (name "Mock USD", symbol
   "mUSD", 6 decimals).
2. Mints the deployer enough mUSD to cover `T_0 + L_{s,0}`.
3. Uses the deployed mUSD address as the backing stable for the rest of
   the genesis ceremony.

The decision is logged in `deploy/sepolia/<timestamp>.json` so that a
follow-up `@sepolia` test run can pick up the correct stable address.

## Operational mitigations (post-deployment)

These are operator-level mitigations, not bytecode-level. Paper §3.4 and
Theorem 5.6 require all three for the MEV-bound claim:

### 1. Private orderflow

- **Ethereum mainnet:** Flashbots Protect RPC for the `routeRevenue`
  transaction. Direct private-mempool submission via `eth_sendBundle`
  for the depositor's bundled transactions.
- **Base / other L2s:** Use the chain's native sequencer-protected
  mempool (Base's sequencer is private by default).
- **Sepolia / fork tests:** No private mempool; tests must not assume
  the mitigation is in effect.

### 2. Uniform random delay

Between the operator's monthly "tick" (e.g. the end of an accounting
period) and the actual `routeRevenue` call, apply a uniform random
delay `τ ~ U[0, 12h]`. The delay decorrelates the buy timing from
public schedule-knowledge.

Implementation in the off-chain scheduler:

```python
import secrets
from datetime import datetime, timedelta
delay_seconds = secrets.randbelow(12 * 60 * 60)
execute_at = tick_at + timedelta(seconds=delay_seconds)
```

### 3. TWAP execution

Optional: split the monthly buy into `N` sub-buys spread across the
delay window. The TWAP scheduler chooses the split count and per-sub-buy
timing independently of public signals.

## Post-deployment verification

After `execute()` returns:

- [ ] `token.totalSupply() == 10^9 · 10^18`.
- [ ] `stable.balanceOf(treasury) == T_0`.
- [ ] `token.balanceOf(hook) == 0` (LP holds the position, not the hook
      directly — depends on V4 position-ownership semantics).
- [ ] `vestingWallet.releasable(token) == 0` immediately post-deploy
      (modulo any test-config `duration = 0` schedule).
- [ ] Pool `slot0().sqrtPriceX96` corresponds to `Spot_0 = L_{s,0} / L_{t,0}`.
- [ ] All four contract addresses verified on the chain's block explorer
      (via `hardhat-verify`).
- [ ] `M2Token`'s `floorPrice()` returns the expected genesis floor.
- [ ] Smoke test: 1 wei `routeRevenue` from depositor succeeds.

## Live Sepolia procedure (Phase 7)

The full step-by-step is documented in `KEYSTORE.md` under
"Phase 7: Sepolia live deployment". TL;DR:

```bash
# 1. Configure secrets (one-time).
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
npx hardhat keystore set ETHERSCAN_API_KEY   # optional

# 2. Fund the deployer with >= 0.05 Sepolia ETH. Circle USDC Sepolia
#    is optional — if absent the script falls back to MockStable.

# 3. Sanity-check the path locally first (REQUIRED).
npm run dryrun:sepolia                       # writes deploy/sepolia/dry_run_manifest.json

# 4. Live deploy.
npm run deploy:sepolia                       # writes deploy/sepolia/manifest.json

# 5. End-to-end smoke test (routeRevenue → lpBuy → lpSell → collectFees → redeem).
npm run e2e:sepolia                          # appends `e2e` block to manifest.json

# 6. Optional: Etherscan verification.
#    Use the addresses + ctor args from deploy/sepolia/manifest.json.
npx hardhat verify --network sepolia <addr> <ctor-args>
```

The factory address depends on the deployer EOA's nonce; the hook
address depends on the (factory, hookSalt, hookCreationCode). The
script re-mines the hook salt for the actual factory address on each
run — there is no "predicted factory address" the user must compute
manually.

After a successful deploy, the e2e test
(`test/integration/SepoliaEndToEnd.test.ts`) is automatically picked up
by `npm run test:sepolia` (the `@sepolia`-tagged suite reads the
manifest and asserts the live on-chain wiring).

## Recovery posture

There is no recovery. The four immutable contracts cannot be paused,
upgraded, or have their parameters changed. If a deployment errs in any
parameter set in the constructor (including the backing-stable choice,
the depositor address, the V4 pool key, or the vesting recipients), the
remedy is to deploy a new system at a new set of addresses.

This is the design's central trust-minimization claim and is not
negotiable.
