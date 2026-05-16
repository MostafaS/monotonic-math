# Contracts (placeholder)

The Solidity reference implementation of the M² protocol described in [`../paper/main.pdf`](../paper/main.pdf) will be developed here.

**Current status:** pre-implementation. The paper §3 (Protocol Specification) is the authoritative spec.

When the contracts land, this folder will be a **Hardhat v3** project containing:

- `contracts/` — the four immutable contracts (Token, Treasury, RevenueRouter, V4Hook), pinned to `solc 0.8.34`
- `test/` — Solidity invariant tests (`.t.sol` files using `forge-std`-style assertions) asserting the floor-monotonicity property of Theorem 4.2, executed by Hardhat v3's native EDR (Ethereum Development Runtime) — **not** by Foundry's `forge` binary. There is no `foundry.toml`.
- `scripts/` — TypeScript deployment scripts using the Hardhat v3 viem-connection pattern
- `hardhat.config.ts` — Hardhat v3 configuration (toolbox-viem plugin)
- `package.json`, `tsconfig.json` — Node / TypeScript setup

The Solidity-test ergonomics (`.t.sol`, `forge-std` imports, fuzz-and-invariant assertions) match Foundry's, but the runtime is Hardhat v3's EDR. This combines Foundry-grade test ergonomics with Hardhat's deployment, plugin, and TypeScript ecosystem.

**Audit budget:** USD 80k–150k from a top-tier firm; see the paper §8.1.
