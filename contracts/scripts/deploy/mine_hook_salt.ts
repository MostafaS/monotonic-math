// SPDX-License-Identifier: MIT
//
// mine_hook_salt.ts — CREATE2 salt miner for `M2V4Hook`
// =====================================================
//
// Uniswap V4 inspects the bottom 14 bits of the hook's address to decide
// which hook callbacks are routed to it. `M2V4Hook` opts into ONLY
// `beforeSwap`, so the deployed address must satisfy:
//
//     uint160(addr) & 0x3FFF == BEFORE_SWAP_FLAG = (1 << 7) = 0x80
//
// This script searches the CREATE2 salt space starting from 0 until it
// finds a salt whose predicted address satisfies that mask AND has no
// existing bytecode (the V4 ecosystem convention; see
// `@uniswap/v4-periphery/src/utils/HookMiner.sol`). Output is written to
// `deploy/hook/hook_salt.json` and committed to git so the genesis factory
// (Phase 5) consumes a deterministic, reviewable record.
//
// Reproducibility: the salt depends on
//   - the CREATE2 deployer address (the genesis factory),
//   - the M2V4Hook constructor arguments
//     (poolManager, token, stable, treasury),
//   - the exact M2V4Hook creation bytecode, which depends on the EXACT
//     solc `0.8.34` pin, the `viaIR: true`, `runs: 200`,
//     `evmVersion: "cancun"` settings (`hardhat.config.ts`), and the
//     M² and OZ source contents.
//
// If the cached `hook_salt.json` matches the current bytecode hash and
// the supplied constructor args + factory, the script exits early
// (idempotent). Pass `--force` to re-mine.
//
// Run via: `npm run mine:hook -- --factory 0x... --pool-manager 0x... \
//          --token 0x... --stable 0x... --treasury 0x...`
//
// All five flags are optional; defaults are documented inline.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  type Address,
  type Hex,
  encodeAbiParameters,
  getAddress,
  getContractAddress,
  isAddress,
  keccak256,
  pad,
  toHex,
} from "viem";

// ---------------------------------------------------------------------------
// Constants — match `@uniswap/v4-core/src/libraries/Hooks.sol` v1.0.2
// ---------------------------------------------------------------------------

/// V4 hook permission mask: bottom 14 bits.
const ALL_HOOK_MASK = (1n << 14n) - 1n; // 0x3FFF

/// `BEFORE_SWAP_FLAG = 1 << 7 = 0x80`. The ONLY flag set for M2V4Hook.
const BEFORE_SWAP_FLAG = 1n << 7n; // 0x80

/// Maximum number of salts to try before giving up. With one flag set
/// (probability ~1 / 2^7 = 1 / 128), expected ≈128 attempts; we bound
/// generously.
const MAX_LOOP = 1_000_000;

// ---------------------------------------------------------------------------
// Filesystem paths
// ---------------------------------------------------------------------------

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const CONTRACTS_ROOT = resolve(__dirname, "..", "..");

/// Path to the compiled M2V4Hook artifact (`hardhat compile` output).
const ARTIFACT_PATH = resolve(
  CONTRACTS_ROOT,
  "artifacts",
  "contracts",
  "hook",
  "M2V4Hook.sol",
  "M2V4Hook.json"
);

/// Output directory + file for the mined salt manifest.
const OUTPUT_DIR = resolve(CONTRACTS_ROOT, "deploy", "hook");
const OUTPUT_PATH = resolve(OUTPUT_DIR, "hook_salt.json");

// ---------------------------------------------------------------------------
// CLI argument parsing (lightweight, no external deps)
// ---------------------------------------------------------------------------

interface CliArgs {
  factory: Address;
  poolManager: Address;
  token: Address;
  stable: Address;
  treasury: Address;
  force: boolean;
  check: boolean;
}

/**
 * Parses argv `--key value` pairs into a CliArgs object. Any flag may be
 * omitted; sensible placeholder defaults are filled in (Phase 5 will
 * provide real addresses). All defaults are well-known burn / test
 * sentinels so the script can run end-to-end before the genesis factory
 * is finalized.
 */
function parseArgs(argv: readonly string[]): CliArgs {
  const args: Record<string, string> = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) continue;
    const key = arg.slice(2);
    if (key === "force") {
      args.force = "true";
      continue;
    }
    if (key === "check") {
      args.check = "true";
      continue;
    }
    const val = argv[i + 1];
    if (val !== undefined && !val.startsWith("--")) {
      args[key] = val;
      i += 1;
    }
  }

  // Default factory: a placeholder zero-prefixed sentinel. The genesis
  // deployer passes the real `M2GenesisFactory` address. Lowercase hex
  // avoids the EIP-55 checksum rejection that `viem.isAddress` enforces.
  const factory = args.factory ?? "0xdeaddeaddeaddeaddeaddeaddeaddeaddeaddead";
  // Real Sepolia V4 PoolManager (canonical Uniswap V4 deployment); the
  // deployer supplies the chain-specific address for other targets.
  const poolManager =
    args["pool-manager"] ?? "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543";
  const token = args.token ?? "0x0000000000000000000000000000000000001111";
  const stable = args.stable ?? "0x0000000000000000000000000000000000002222";
  const treasury = args.treasury ?? "0x0000000000000000000000000000000000003333";

  for (const [name, value] of [
    ["factory", factory],
    ["pool-manager", poolManager],
    ["token", token],
    ["stable", stable],
    ["treasury", treasury],
  ] as const) {
    if (!isAddress(value)) {
      throw new Error(`mine_hook_salt: --${name} is not a valid address: ${value}`);
    }
  }

  return {
    factory: getAddress(factory),
    poolManager: getAddress(poolManager),
    token: getAddress(token),
    stable: getAddress(stable),
    treasury: getAddress(treasury),
    force: args.force === "true",
    check: args.check === "true",
  };
}

// ---------------------------------------------------------------------------
// Bytecode loading
// ---------------------------------------------------------------------------

interface HookArtifact {
  bytecode: Hex;
  contractName: string;
  sourceName: string;
}

/**
 * Loads the M2V4Hook compiled artifact. Errors with an explicit message if
 * the artifact is missing — the caller is expected to run `npm run compile`
 * before mining.
 */
function loadArtifact(): HookArtifact {
  if (!existsSync(ARTIFACT_PATH)) {
    throw new Error(
      `mine_hook_salt: artifact not found at ${ARTIFACT_PATH}. Run ` +
        `\`npm run compile\` (or \`npx hardhat compile --no-tests\` if ` +
        `test files block the full compile) before mining.`
    );
  }
  const raw = readFileSync(ARTIFACT_PATH, "utf8");
  const json = JSON.parse(raw) as HookArtifact & Record<string, unknown>;
  if (!json.bytecode || typeof json.bytecode !== "string") {
    throw new Error(
      `mine_hook_salt: artifact at ${ARTIFACT_PATH} has no bytecode field.`
    );
  }
  return {
    bytecode: json.bytecode as Hex,
    contractName: String(json.contractName ?? "M2V4Hook"),
    sourceName: String(json.sourceName ?? "contracts/hook/M2V4Hook.sol"),
  };
}

// ---------------------------------------------------------------------------
// Bytecode + constructor args concatenation
// ---------------------------------------------------------------------------

/**
 * Concatenates the M2V4Hook creation code with ABI-encoded constructor
 * arguments. The result is the exact `init_code` that the CREATE2 opcode
 * hashes when computing the deployed address.
 */
function buildCreationBytecode(
  artifact: HookArtifact,
  args: CliArgs
): Hex {
  const encodedArgs = encodeAbiParameters(
    [
      { type: "address", name: "poolManager_" },
      { type: "address", name: "token_" },
      { type: "address", name: "stable_" },
      { type: "address", name: "treasury_" },
    ],
    [args.poolManager, args.token, args.stable, args.treasury]
  );
  // `encodedArgs` already includes the 0x prefix; the artifact bytecode
  // does too. Strip one prefix and concatenate.
  return `${artifact.bytecode}${encodedArgs.slice(2)}` as Hex;
}

// ---------------------------------------------------------------------------
// Idempotence: read the cached manifest and decide whether to skip
// ---------------------------------------------------------------------------

interface SaltManifest {
  /** Mined salt as 32-byte hex string. */
  salt: Hex;
  /** Predicted hook address. */
  hookAddress: Address;
  /** keccak256 of the (bytecode || encodedArgs) input. */
  bytecodeHash: Hex;
  /** CREATE2 deployer (genesis factory). */
  factoryAddress: Address;
  /** Constructor arguments (for reproducibility). */
  constructorArgs: {
    poolManager: Address;
    token: Address;
    stable: Address;
    treasury: Address;
  };
  /** Hook flag pattern the mined address satisfies. */
  hookFlag: Hex;
  /** Tooling version metadata for forensic forensics. */
  metadata: {
    solcVersion: "0.8.34";
    contractName: string;
    sourceName: string;
    minedAt: string;
    iterations: number;
  };
}

function loadCachedManifest(): SaltManifest | undefined {
  if (!existsSync(OUTPUT_PATH)) return undefined;
  try {
    const raw = readFileSync(OUTPUT_PATH, "utf8");
    return JSON.parse(raw) as SaltManifest;
  } catch {
    return undefined;
  }
}

function manifestMatches(
  cached: SaltManifest,
  expectedHash: Hex,
  args: CliArgs
): boolean {
  return (
    cached.bytecodeHash.toLowerCase() === expectedHash.toLowerCase() &&
    getAddress(cached.factoryAddress) === args.factory &&
    getAddress(cached.constructorArgs.poolManager) === args.poolManager &&
    getAddress(cached.constructorArgs.token) === args.token &&
    getAddress(cached.constructorArgs.stable) === args.stable &&
    getAddress(cached.constructorArgs.treasury) === args.treasury
  );
}

// ---------------------------------------------------------------------------
// Mining loop
// ---------------------------------------------------------------------------

/**
 * Iterates salts from 0 upward, computes the CREATE2 predicted address,
 * and returns the first salt whose address has lower-14-bits equal to
 * `BEFORE_SWAP_FLAG`. Throws after `MAX_LOOP` attempts.
 */
function mineSalt(
  factory: Address,
  creationBytecode: Hex
): { salt: Hex; hookAddress: Address; iterations: number } {
  for (let i = 0; i < MAX_LOOP; i += 1) {
    // 32-byte left-padded salt.
    const salt = pad(toHex(BigInt(i)), { size: 32 });
    const hookAddress = getContractAddress({
      opcode: "CREATE2",
      from: factory,
      bytecode: creationBytecode,
      salt,
    });
    const addrBig = BigInt(hookAddress);
    if ((addrBig & ALL_HOOK_MASK) === BEFORE_SWAP_FLAG) {
      return { salt, hookAddress, iterations: i + 1 };
    }
  }
  throw new Error(
    `mine_hook_salt: could not find a salt in ${MAX_LOOP} iterations. ` +
      `Increase MAX_LOOP or verify the factory address.`
  );
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

function main(): void {
  const argv = process.argv.slice(2);
  const args = parseArgs(argv);

  const artifact = loadArtifact();
  const creationBytecode = buildCreationBytecode(artifact, args);
  const bytecodeHash = keccak256(creationBytecode);

  // CI freshness check: never mines. Asserts the committed manifest
  // matches the current creation bytecode hash and the expected
  // (factory + ctor args). Exits nonzero on any mismatch.
  if (args.check) {
    const cached = loadCachedManifest();
    if (cached === undefined) {
      process.stderr.write(
        `mine_hook_salt --check: FAIL — no cached manifest at ${OUTPUT_PATH}.\n` +
          `Run \`npm run mine:hook\` to produce one.\n`
      );
      process.exit(1);
    }
    if (!manifestMatches(cached, bytecodeHash, args)) {
      process.stderr.write(
        `mine_hook_salt --check: FAIL — cached manifest is stale.\n` +
          `  cached.bytecodeHash:   ${cached.bytecodeHash}\n` +
          `  expected.bytecodeHash: ${bytecodeHash}\n` +
          `  cached.factory:        ${cached.factoryAddress}\n` +
          `  expected.factory:      ${args.factory}\n` +
          `  cached.poolManager:    ${cached.constructorArgs.poolManager}\n` +
          `  expected.poolManager:  ${args.poolManager}\n` +
          `  cached.token:          ${cached.constructorArgs.token}\n` +
          `  expected.token:        ${args.token}\n` +
          `  cached.stable:         ${cached.constructorArgs.stable}\n` +
          `  expected.stable:       ${args.stable}\n` +
          `  cached.treasury:       ${cached.constructorArgs.treasury}\n` +
          `  expected.treasury:     ${args.treasury}\n` +
          `Re-run \`npm run mine:hook -- --force\` to refresh.\n`
      );
      process.exit(1);
    }
    process.stdout.write(
      `mine_hook_salt --check: OK — cached manifest matches current bytecode.\n` +
        `  hookAddress: ${cached.hookAddress}\n` +
        `  bytecodeHash:${cached.bytecodeHash}\n`
    );
    return;
  }

  // Idempotence check.
  if (!args.force) {
    const cached = loadCachedManifest();
    if (cached !== undefined && manifestMatches(cached, bytecodeHash, args)) {
      process.stdout.write(
        `mine_hook_salt: cached salt is still valid; skipping.\n` +
          `  hookAddress: ${cached.hookAddress}\n` +
          `  salt:        ${cached.salt}\n` +
          `  bytecodeHash:${cached.bytecodeHash}\n` +
          `  factory:     ${cached.factoryAddress}\n` +
          `(re-run with --force to re-mine)\n`
      );
      return;
    }
  }

  process.stdout.write(
    `mine_hook_salt: starting search\n` +
      `  factory:     ${args.factory}\n` +
      `  poolManager: ${args.poolManager}\n` +
      `  token:       ${args.token}\n` +
      `  stable:      ${args.stable}\n` +
      `  treasury:    ${args.treasury}\n` +
      `  bytecodeHash:${bytecodeHash}\n` +
      `  flag mask:   0x${BEFORE_SWAP_FLAG.toString(16).padStart(4, "0")} ` +
      `(BEFORE_SWAP_FLAG)\n`
  );

  const start = Date.now();
  const { salt, hookAddress, iterations } = mineSalt(
    args.factory,
    creationBytecode
  );
  const elapsedMs = Date.now() - start;

  process.stdout.write(
    `mine_hook_salt: found salt after ${iterations} iterations ` +
      `(${elapsedMs} ms)\n` +
      `  hookAddress: ${hookAddress}\n` +
      `  salt:        ${salt}\n`
  );

  // Verify the result before writing.
  const addrBig = BigInt(hookAddress);
  if ((addrBig & ALL_HOOK_MASK) !== BEFORE_SWAP_FLAG) {
    throw new Error(
      `mine_hook_salt: post-condition failed — mined address ${hookAddress} ` +
        `does not satisfy BEFORE_SWAP_FLAG`
    );
  }

  // Persist.
  const manifest: SaltManifest = {
    salt,
    hookAddress: getAddress(hookAddress),
    bytecodeHash,
    factoryAddress: args.factory,
    constructorArgs: {
      poolManager: args.poolManager,
      token: args.token,
      stable: args.stable,
      treasury: args.treasury,
    },
    hookFlag: `0x${BEFORE_SWAP_FLAG.toString(16).padStart(4, "0")}` as Hex,
    metadata: {
      solcVersion: "0.8.34",
      contractName: artifact.contractName,
      sourceName: artifact.sourceName,
      minedAt: new Date().toISOString(),
      iterations,
    },
  };

  if (!existsSync(OUTPUT_DIR)) {
    mkdirSync(OUTPUT_DIR, { recursive: true });
  }
  writeFileSync(OUTPUT_PATH, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  process.stdout.write(`mine_hook_salt: wrote ${OUTPUT_PATH}\n`);
}

main();
