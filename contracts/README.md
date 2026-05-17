# M² Contracts

Solidity reference implementation of the M² protocol described in
[`../paper/main.pdf`](../paper/main.pdf). The protocol is a fixed-supply
ERC-20 token whose redemption floor `F = T / S` is provably non-decreasing
under every protocol-defined state transition (paper §4).

## Architecture

Four immutable contracts plus a one-shot CREATE2 factory:

| Contract | Role |
|---|---|
| `M2Token` | ERC-20 with `redeem(amount)` paying `mulDiv(amount, T, S)` from the treasury. Single genesis mint; three immutable burn-authority addresses (hook, router, self). |
| `M2Treasury` | Passive custody of the backing stablecoin. The only privileged outflow is `payRedemption`, callable solely by the token contract. |
| `M2RevenueRouter` | Pulls revenue from an immutable depositor, deposits half into the treasury, uses the other half to buy M² on the V4 pool, and burns the tokens received in the same transaction. |
| `M2V4Hook` | Uniswap v4 hook owning the LP position permanently. `beforeSwap` returns a per-direction fee override (0.10 % on buy, 3.00 % on sell). Exposes a permissionless `collectFees()` that realises accrued v4 fees, burns 99.75 % of the token side, sends 99.75 % of the stable side to the treasury, and pays the caller a 0.25 % bounty per side. |
| `M2GenesisFactory` | Single non-reentrant `execute()` that deploys all four contracts, seeds the treasury, initialises the v4 pool with a full-range LP position, sets up OpenZeppelin `VestingWallet`s, and verifies the floor-spot constraint `T₀·Lt₀ == Ls₀·S₀`. No finalize fallback, no two-tx pattern. |

The four immutable contracts have no admin, no governance, no upgrade path,
no pause, and no rescue function. Privilege gating is exclusively via
constructor-set immutable addresses.

## Toolchain

| Item | Pinned value |
|---|---|
| Solidity | `0.8.34` exact (no caret) |
| Build / test | Hardhat v3 (`^3.1`) with EDR |
| Node | ESM (`"type": "module"`) |
| JS client | viem `^2.43` via `@nomicfoundation/hardhat-viem` |
| Compiler settings | `viaIR: true`, `optimizer.runs: 200`, `evmVersion: "cancun"` |
| ERC-20 base | OpenZeppelin Contracts v5 |
| AMM | Uniswap v4 core + periphery (pinned exact) |
| Secrets | Hardhat keystore (`configVariable(...)`); no `.env` |
| Static analysis | Solhint with `avoid-suicide`, `avoid-tx-origin`, `avoid-throw`, `no-inline-assembly`; Slither (release-gate) |

## Quickstart

```bash
npm install
npm run compile
npm run lint
npm run test:unit
npm run test:integration
npm run test:invariant
```

The full CI chain runs in one command:

```bash
npm run ci
# compile + check:pragma + check:hook-salt + lint
# + audit:bytecode + audit:inheritance
# + test:reference + test:agreement
# + test:unit + test:integration + test:invariant + test:differential
```

The slow gate (≥ 10 k fuzz runs per stateless property, ≥ 100 k stateful
sequences × depth 200, mainnet-fork tests):

```bash
npm run test:invariant:full
M2_ENABLE_FORK_TESTS=1 npm run test:fork   # requires MAINNET_RPC_URL keystore
```

## Test layout

```
test/
  helpers/          # local Vm + assertion helpers (no forge-std import)
  reference/        # bigint TypeScript reference state machine
  unit/             # *.t.sol per-contract unit tests
  integration/      # V4-backed integration tests (paired token/stable
                    # address-sort fixtures)
  invariant/        # stateful + stateless fuzz against MockAMM
```

Solidity tests are `.t.sol` files executed by Hardhat v3's EDR. There is no
Foundry binary, no `foundry.toml`, and no `forge-std` import.

## Secrets

All keystore-managed secrets are documented in [`KEYSTORE.md`](./KEYSTORE.md).
Required keys for Sepolia deployment and mainnet-fork tests:

```bash
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
npx hardhat keystore set MAINNET_RPC_URL
npx hardhat keystore set ETHERSCAN_API_KEY
```

## Deployment

```bash
# Dry-run end-to-end on a local EDR (no secrets required)
npm run dryrun:sepolia

# Live Sepolia deployment + 6-step end-to-end smoke test
npm run deploy:sepolia
npm run e2e:sepolia
```

The hook's CREATE2 address must satisfy v4's `BEFORE_SWAP_FLAG` permission
bit. `scripts/deploy/mine_hook_salt.ts` mines the salt; the mined manifest
is committed under `deploy/hook/hook_salt.json` and re-verified by the
`check:hook-salt` CI gate against the current bytecode hash.

## Paper claim → test mapping

Every numbered theorem, lemma, and corollary in the paper maps to a test
file. The mapping is enumerated in [`docs/paper_claim_to_test.md`](./docs/paper_claim_to_test.md).
Headline differentials:

- **Lemma 4.2** (integer redemption residual identity) — `test/invariant/Lemma4_2ResidualIdentity.t.sol` at ≥ 10 000 runs.
- **Theorem 4.3** (floor monotonicity across the seven-class operation set) — `test/invariant/FloorMonotonicityInvariant.t.sol`.
- **Theorem 4.5** (no first-mover advantage in redemption) — `test/integration/Theorem4_5RedemptionFairness.t.sol`.
- **Theorem 5.2** (bank-run premium `Δ* ≈ $21,476.5621…`) — `test/integration/Theorem5_2BankRun.t.sol` (executes the saturated mixed strategy through the real V4 pool and verifies the on-chain delta against the closed form within ≤ 0.5 %).
- **Theorem 5.3 (2)** (spot-floor arbitrage pin) — `test/integration/Theorem5_3SpotFloorArbitragePin.t.sol`.

## License

MIT. See the project-root [`LICENSE`](../LICENSE).
