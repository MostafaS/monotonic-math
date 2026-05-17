// SPDX-License-Identifier: MIT
//
// Hardhat v3 configuration for M² / Monotonic Math.
//
// Locked toolchain (do not deviate):
//   - solc 0.8.34 exact pin (no caret). 0.8.28–0.8.33 ship a via-IR transient
//     storage clearing bug; 0.8.34 fixes it. V4 hooks use transient storage
//     heavily, so the floor of the pin matters.
//   - viaIR: true, optimizer.runs: 200, evmVersion: "cancun".
//   - ESM, viem (no ethers), Hardhat keystore (no .env).
//   - Plugins installed individually (no toolbox bundle).
import HardhatViem from "@nomicfoundation/hardhat-viem";
import HardhatKeystore from "@nomicfoundation/hardhat-keystore";
import HardhatVerify from "@nomicfoundation/hardhat-verify";
import HardhatNodeTestRunner from "@nomicfoundation/hardhat-node-test-runner";
import HardhatNetworkHelpers from "@nomicfoundation/hardhat-network-helpers";
import HardhatViemAssertions from "@nomicfoundation/hardhat-viem-assertions";
import { configVariable, defineConfig } from "hardhat/config";

// -----------------------------------------------------------------------------
// Phase 3/4 invariant + fuzz runner knobs.
//
// Defaults are calibrated for development cycles (Phase 3 acceptance: pass at
// runs >= 1000, depth >= 50). For the production-grade Phase 4/8 sweep, scale
// via environment variables (see scripts in package.json):
//
//   M2_FUZZ_RUNS=10000 M2_INVARIANT_RUNS=100000 M2_INVARIANT_DEPTH=200 \
//     npm run test:invariant
//
// EDR's `test.solidity.fuzz` and `test.solidity.invariant` accept the same
// knob names Foundry uses (see node_modules/hardhat/src/internal/builtin-
// plugins/solidity-test/type-extensions.ts).
// -----------------------------------------------------------------------------
const fuzzRuns = Number(process.env.M2_FUZZ_RUNS ?? 1000);
const invariantRuns = Number(process.env.M2_INVARIANT_RUNS ?? 1000);
const invariantDepth = Number(process.env.M2_INVARIANT_DEPTH ?? 50);

// -----------------------------------------------------------------------------
// Phase 6 mainnet-fork knob.
//
// EDR's Solidity-test runner supports forking via `test.solidity.forking`.
// The fork URL must come from the Hardhat keystore via `configVariable(...)`.
// To avoid forcing every CI lane to provide a mainnet RPC URL, the fork
// block is enabled ONLY when the environment variable `M2_ENABLE_FORK_TESTS`
// is set (any non-empty value). When unset, the .t.sol fork tests detect
// the missing fork via the absence of bytecode at the canonical USDC and
// V4 PoolManager addresses and skip gracefully.
//
// Pinned block: 22_000_000 — selected because V4 PoolManager is deployed
// by this block and the state is stable. To re-pin for reproducibility
// reasons, update this constant and the `_PINNED_FORK_BLOCK` references
// in the Phase 6 fork tests in lockstep.
// -----------------------------------------------------------------------------
const ENABLE_FORK_TESTS = Boolean(process.env.M2_ENABLE_FORK_TESTS);
const PINNED_FORK_BLOCK = 22_000_000n;

export default defineConfig({
  plugins: [
    HardhatViem,
    HardhatKeystore,
    HardhatVerify,
    HardhatNodeTestRunner,
    HardhatNetworkHelpers,
    HardhatViemAssertions,
  ],
  solidity: {
    profiles: {
      default: {
        compilers: [
          {
            version: "0.8.34",
            settings: {
              viaIR: true,
              optimizer: {
                enabled: true,
                runs: 200,
              },
              evmVersion: "cancun",
            },
          },
          // V4 core / periphery upstream sources are pinned to 0.8.26
          // (e.g. PoolManager.sol uses `pragma solidity 0.8.26;`). The
          // check:pragma script scans only contracts/ and test/, so adding
          // a second compiler version here does not relax the M²-code
          // pragma lock — it only enables compiling the V4 dependency.
          // Bytecode-equivalence: V4's pragma is exact-pin, so the
          // compiled bytecode matches the canonical V4 deployment.
          {
            version: "0.8.26",
            settings: {
              viaIR: true,
              optimizer: {
                enabled: true,
                runs: 200,
              },
              evmVersion: "cancun",
            },
          },
        ],
        // Phase 5 size note: the genesis factory accepts the hook's
        // creation bytecode as a `bytes` argument so it does NOT embed
        // M2V4Hook's ~9 KiB creation code as a compile-time literal.
        // Treasury / Token / Router are still embedded via `new` (each
        // contributes its compiled creation code to the factory's
        // bytecode); current runtime size is well under EIP-170's
        // 24 576-byte cap at default `runs: 200`.
      },
    },
    remappings: [
      "@openzeppelin/contracts/=node_modules/@openzeppelin/contracts/",
      "@uniswap/v4-core/=node_modules/@uniswap/v4-core/",
      "@uniswap/v4-periphery/=node_modules/@uniswap/v4-periphery/",
    ],
  },
  test: {
    solidity: {
      fuzz: {
        runs: fuzzRuns,
      },
      invariant: {
        runs: invariantRuns,
        depth: invariantDepth,
        failOnRevert: false,
        callOverride: false,
      },
      // Mainnet-fork configuration for the EDR Solidity-test runner.
      // Only present when `M2_ENABLE_FORK_TESTS` is set — see the
      // PINNED_FORK_BLOCK + ENABLE_FORK_TESTS block above. When absent,
      // the Phase 6 .t.sol fork tests detect the missing fork via
      // bytecode probes on USDC + V4 PoolManager and skip gracefully.
      ...(ENABLE_FORK_TESTS
        ? {
            forking: {
              url: configVariable("MAINNET_RPC_URL"),
              blockNumber: PINNED_FORK_BLOCK,
            },
          }
        : {}),
    },
  },
  networks: {
    hardhat: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatFork: {
      type: "edr-simulated",
      chainType: "l1",
      // Pin to a mainnet block where V4 PoolManager is deployed and the
      // canonical mainnet USDC contract is live. Block 22_000_000 is well
      // past V4's mainnet deployment (~21.7M) and stable across CI runs.
      // Owner must set MAINNET_RPC_URL in the keystore for tests that
      // run under `--network hardhatFork`; without it, the network-level
      // fork is unavailable and the .t.sol fork tests fall back to a
      // graceful skip (see `_isForkAvailable()` in those test files).
      forking: {
        url: configVariable("MAINNET_RPC_URL"),
        blockNumber: PINNED_FORK_BLOCK,
      },
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
  },
  verify: {
    etherscan: {
      apiKey: configVariable("ETHERSCAN_API_KEY"),
    },
  },
});
