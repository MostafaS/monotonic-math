// SPDX-License-Identifier: MIT
//
// 01_deploy_canonical.ts — Single-tx M² genesis deploy script (Hardhat v3 + viem)
// ===============================================================================
//
// Drives `M2GenesisFactory.execute()` end-to-end:
//   1. Read network + addresses (PoolManager, USDC) from keystore-backed env.
//   2. Build canonical params for the canonical 2-recipient genesis schedule
//      (test config: duration=0; production deployments override this).
//   3. Pre-compute the four CREATE addresses from the factory's nonce, the
//      hook CREATE2 address from the mined salt, the BEFORE_SWAP_FLAG hook
//      address validation.
//   4. Approve the factory for (T0 + LS0) stable.
//   5. Call factory.execute(params) and wait for the receipt.
//   6. Persist the deployed addresses to deploy/<chainId>/manifest.json.
//
// Run via:
//   npx hardhat run scripts/deploy/01_deploy_canonical.ts --network <network>
//
// On `--network hardhat` the script deploys a MockStable and a fresh V4
// PoolManager (the local Hardhat node does not have a pre-existing V4
// deployment). On `--network sepolia` / `--network mainnet` the script
// reads chain-specific addresses from `keystore` and uses real USDC + V4
// PoolManager.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import hre from "hardhat";
import {
  type Address,
  type Hex,
  encodeAbiParameters,
  getAddress,
  getContractAddress,
  keccak256,
  pad,
  toHex,
} from "viem";

// ---------------------------------------------------------------------------
// Filesystem paths
// ---------------------------------------------------------------------------

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const CONTRACTS_ROOT = resolve(__dirname, "..", "..");
const HOOK_SALT_PATH = resolve(CONTRACTS_ROOT, "deploy", "hook", "hook_salt.json");

// ---------------------------------------------------------------------------
// Constants (mirror M2Constants.sol)
// ---------------------------------------------------------------------------

const S0 = 1_000_000_000n * 10n ** 18n; // total supply
const LT0 = 750_000_000n * 10n ** 18n; // LP seed (tokens)
const VESTING_TOTAL = 250_000_000n * 10n ** 18n; // vesting seed (tokens)

const ALL_HOOK_MASK = (1n << 14n) - 1n;
const BEFORE_SWAP_FLAG = 1n << 7n;

// ---------------------------------------------------------------------------
// Canonical seed (USDC-style, d_s = 6)
// ---------------------------------------------------------------------------

const T0_USDC = 1_000_000n * 10n ** 6n; // $1M
const LS0_USDC = 750_000n * 10n ** 6n; // $750k

// ---------------------------------------------------------------------------
// Genesis recipient schedule (test config)
// ---------------------------------------------------------------------------
//
// Production deployments override this with the real (cliff, duration,
// recipients) schedule per docs/deployment_runbook.md. The default
// schedule here is the §3.7 mass-dump test config (`duration = 0`).
const TEST_RECIPIENT_A: Address = getAddress(
  "0x00000000000000000000000000000000be9ef1ca",
);
const TEST_RECIPIENT_B: Address = getAddress(
  "0x00000000000000000000000000000000be9ef1cb",
);

// ---------------------------------------------------------------------------
// CREATE address prediction (RLP for small nonces)
// ---------------------------------------------------------------------------

function predictCreate(deployer: Address, nonce: number): Address {
  if (nonce < 1 || nonce > 0x7f) {
    throw new Error(`predictCreate: nonce ${nonce} out of supported range`);
  }
  const rlp = `0xd694${deployer.slice(2)}${nonce.toString(16).padStart(2, "0")}` as Hex;
  const hash = keccak256(rlp);
  return `0x${hash.slice(26)}` as Address;
}

// ---------------------------------------------------------------------------
// Hook salt loader (uses the pre-committed mine_hook_salt.ts output as a
// fallback; the script re-mines locally if the cached salt does not match
// the current bytecode + factory address.)
// ---------------------------------------------------------------------------

interface HookSaltManifest {
  salt: Hex;
  hookAddress: Address;
  bytecodeHash: Hex;
  factoryAddress: Address;
}

function loadCachedHookSalt(): HookSaltManifest | undefined {
  if (!existsSync(HOOK_SALT_PATH)) return undefined;
  try {
    return JSON.parse(readFileSync(HOOK_SALT_PATH, "utf8")) as HookSaltManifest;
  } catch {
    return undefined;
  }
}

function mineHookSalt(
  factory: Address,
  hookCreationCode: Hex,
  poolManager: Address,
  token: Address,
  stable: Address,
  treasury: Address,
): { salt: Hex; hookAddress: Address; iterations: number } {
  const encodedArgs = encodeAbiParameters(
    [
      { type: "address" },
      { type: "address" },
      { type: "address" },
      { type: "address" },
    ],
    [poolManager, token, stable, treasury],
  );
  const initCode = `${hookCreationCode}${encodedArgs.slice(2)}` as Hex;

  const MAX_LOOP = 1_000_000;
  for (let i = 0; i < MAX_LOOP; i += 1) {
    const salt = pad(toHex(BigInt(i)), { size: 32 });
    const hookAddress = getContractAddress({
      opcode: "CREATE2",
      from: factory,
      bytecode: initCode,
      salt,
    });
    if ((BigInt(hookAddress) & ALL_HOOK_MASK) === BEFORE_SWAP_FLAG) {
      return { salt, hookAddress, iterations: i + 1 };
    }
  }
  throw new Error("mineHookSalt: salt search exhausted");
}

// ---------------------------------------------------------------------------
// Manifest writer
// ---------------------------------------------------------------------------

interface DeploymentManifest {
  network: string;
  chainId: number;
  deployer: Address;
  factory: Address;
  addresses: {
    token: Address;
    treasury: Address;
    router: Address;
    hook: Address;
    poolManager: Address;
    stable: Address;
    vestingWallets: Address[];
  };
  params: {
    treasurySeed: string;
    lpStableSeed: string;
    lpLiquidity: string;
    sqrtPriceX96Initial: string;
    tickSpacing: number;
    depositor: Address;
  };
  txHash: Hex;
  blockNumber: bigint;
  deployedAt: string;
}

function writeManifest(manifest: DeploymentManifest): string {
  const outDir = resolve(CONTRACTS_ROOT, "deploy", String(manifest.chainId));
  if (!existsSync(outDir)) mkdirSync(outDir, { recursive: true });
  const outPath = resolve(outDir, "manifest.json");
  // BigInt stringify
  const replacer = (_key: string, value: unknown) =>
    typeof value === "bigint" ? value.toString() : value;
  writeFileSync(outPath, `${JSON.stringify(manifest, replacer, 2)}\n`, "utf8");
  return outPath;
}

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const connection = await hre.network.connect();
  const viem = (connection as unknown as { viem: any }).viem;
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();
  const deployer = walletClient.account.address as Address;
  const chainId = await publicClient.getChainId();

  process.stdout.write(
    `\n=== M² Genesis Deploy ===\n` +
      `  Network:  ${hre.globalOptions.network ?? "hardhat"}\n` +
      `  ChainId:  ${chainId}\n` +
      `  Deployer: ${deployer}\n`,
  );

  // -------- 1. Resolve PoolManager + Stable for this chain ----------------

  let poolManagerAddr: Address;
  let stableAddr: Address;
  if (chainId === 31337 || chainId === 1337) {
    // Local Hardhat: deploy a fresh V4 PoolManager via the 0.8.26
    // helper (PoolManager.sol is pinned to ^0.8.26 and cannot be
    // deployed from the 0.8.34 compilation unit directly). We simulate
    // the deployer's `deploy` first to learn the resulting address,
    // then send the transaction.
    const pmDeployer = await viem.deployContract(
      "V4PoolManagerDeployer",
      [],
    );
    const sim = await publicClient.simulateContract({
      address: pmDeployer.address,
      abi: pmDeployer.abi,
      functionName: "deploy",
      args: [deployer],
      account: walletClient.account,
    });
    poolManagerAddr = sim.result as Address;
    const deployTx = await walletClient.writeContract(sim.request);
    const deployRcpt = await publicClient.waitForTransactionReceipt({
      hash: deployTx,
    });
    if (deployRcpt.status !== "success") {
      throw new Error(`PoolManager deploy reverted: ${deployTx}`);
    }
    const stable = await viem.deployContract("MockStable", []);
    stableAddr = stable.address;
    process.stdout.write(
      `  PoolManager (local): ${poolManagerAddr}\n` +
        `  MockStable (local):  ${stableAddr}\n`,
    );
  } else if (chainId === 11155111) {
    // Sepolia: canonical V4 + Circle USDC Sepolia faucet token.
    poolManagerAddr = "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543";
    stableAddr = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";
    process.stdout.write(
      `  PoolManager (Sepolia): ${poolManagerAddr}\n` +
        `  USDC (Sepolia):        ${stableAddr}\n`,
    );
  } else if (chainId === 1) {
    // Mainnet: real PoolManager (Phase 5: TBD when canonical V4 is finalized)
    // + real USDC. Placeholder until pinned in the runbook.
    throw new Error("Mainnet deployment: PoolManager address not yet pinned.");
  } else {
    throw new Error(`Unsupported chainId ${chainId}.`);
  }

  // -------- 2. Deploy the factory ----------------------------------------

  const factory = await viem.deployContract("M2GenesisFactory", []);
  const factoryAddr = factory.address as Address;
  process.stdout.write(`  M2GenesisFactory: ${factoryAddr}\n`);

  // -------- 3. Predict treasury/token/router via factory CREATE nonces ----

  const predictedTreasury = predictCreate(factoryAddr, 1);
  const predictedToken = predictCreate(factoryAddr, 2);
  const predictedRouter = predictCreate(factoryAddr, 4);

  // -------- 4. Mine the hook salt (or use cached if it still matches) -----

  const hookArtifact = await hre.artifacts.readArtifact("M2V4Hook");
  const hookCreationCode = hookArtifact.bytecode as Hex;

  let hookSalt: Hex;
  let predictedHook: Address;

  const cached = loadCachedHookSalt();
  // The cached manifest is keyed on (poolManager, token, stable, treasury,
  // factory). It was mined with placeholder addresses; we ALWAYS re-mine
  // here against the actual addresses. The cached file is used only for
  // off-chain prediction during salt mining of the hook BYTECODE hash.
  const minedResult = mineHookSalt(
    factoryAddr,
    hookCreationCode,
    poolManagerAddr,
    predictedToken,
    stableAddr,
    predictedTreasury,
  );
  hookSalt = minedResult.salt;
  predictedHook = minedResult.hookAddress;
  process.stdout.write(
    `  Hook salt:  ${hookSalt} (mined in ${minedResult.iterations} iterations)\n` +
      `  Predicted addresses:\n` +
      `    treasury: ${predictedTreasury}\n` +
      `    token:    ${predictedToken}\n` +
      `    router:   ${predictedRouter}\n` +
      `    hook:     ${predictedHook}\n`,
  );

  // Cached-vs-mined sanity log (informational only).
  if (cached) {
    process.stdout.write(
      `  Cached hook salt (deploy/hook/hook_salt.json) is for factory ` +
        `${cached.factoryAddress} — DIFFERENT from the live factory; ` +
        `using freshly mined salt.\n`,
    );
  }

  // -------- 5. Approve stable + execute the genesis ---------------------

  const stableContract = await viem.getContractAt("MockStable", stableAddr).catch(async () => {
    // For non-Mock stables (USDC) the ABI is still ERC-20 compatible.
    return await viem.getContractAt("IERC20", stableAddr);
  });

  // For local chains the deployer needs to be funded with mUSD first.
  if (chainId === 31337 || chainId === 1337) {
    const mintable = await viem.getContractAt("MockStable", stableAddr);
    const txHash = await mintable.write.mint(
      [deployer, T0_USDC + LS0_USDC],
      { account: walletClient.account },
    );
    await publicClient.waitForTransactionReceipt({ hash: txHash });
  }

  // Approve the factory for (T0 + LS0).
  const approveHash = await stableContract.write.approve(
    [factoryAddr, T0_USDC + LS0_USDC],
    { account: walletClient.account },
  );
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  // Build genesis params.
  const vestingAllocs = [VESTING_TOTAL / 2n, VESTING_TOTAL - VESTING_TOTAL / 2n];
  const now = BigInt(Math.floor(Date.now() / 1000));
  const params = {
    stable: stableAddr,
    poolManager: poolManagerAddr,
    depositor: deployer, // canonical local test: deployer == depositor
    treasurySeed: T0_USDC,
    lpStableSeed: LS0_USDC,
    lpLiquidity: 1_000_000n, // minimal for the smoke deploy
    sqrtPriceX96Initial: 1n << 96n,
    tickSpacing: 60,
    hookSalt,
    hookCreationCode,
    vestingRecipients: [TEST_RECIPIENT_A, TEST_RECIPIENT_B],
    vestingStarts: [now, now],
    vestingDurations: [0n, 0n],
    vestingAllocations: vestingAllocs,
  };

  process.stdout.write(`  Calling factory.execute()...\n`);
  const txHash = await factory.write.execute([params], {
    account: walletClient.account,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  if (receipt.status !== "success") {
    throw new Error(`genesis tx reverted: ${txHash}`);
  }

  // -------- 6. Persist the manifest --------------------------------------

  const manifest: DeploymentManifest = {
    network: hre.globalOptions.network ?? "hardhat",
    chainId,
    deployer,
    factory: factoryAddr,
    addresses: {
      token: predictedToken,
      treasury: predictedTreasury,
      router: predictedRouter,
      hook: predictedHook,
      poolManager: poolManagerAddr,
      stable: stableAddr,
      // Vesting wallet addresses are deterministic from the factory's
      // nonces 5, 6, ..., 4+N where N = recipients.length.
      vestingWallets: vestingAllocs.map((_, i) =>
        predictCreate(factoryAddr, 5 + i),
      ),
    },
    params: {
      treasurySeed: T0_USDC.toString(),
      lpStableSeed: LS0_USDC.toString(),
      lpLiquidity: "1000000",
      sqrtPriceX96Initial: (1n << 96n).toString(),
      tickSpacing: 60,
      depositor: deployer,
    },
    txHash,
    blockNumber: receipt.blockNumber,
    deployedAt: new Date().toISOString(),
  };

  const manifestPath = writeManifest(manifest);
  process.stdout.write(
    `\n  Genesis complete!\n` +
      `    tx hash:  ${txHash}\n` +
      `    block:    ${receipt.blockNumber}\n` +
      `    gas used: ${receipt.gasUsed}\n` +
      `    manifest: ${manifestPath}\n\n`,
  );
}

main().catch((err) => {
  process.stderr.write(`${err instanceof Error ? err.stack : String(err)}\n`);
  process.exit(1);
});
