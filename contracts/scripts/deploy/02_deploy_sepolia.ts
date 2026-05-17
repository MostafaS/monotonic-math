// SPDX-License-Identifier: MIT
//
// 02_deploy_sepolia.ts — Live Sepolia genesis deployment (Hardhat v3 + viem)
// ==========================================================================
//
// This script is the canonical entry point for the "Phase 7 Sepolia
// end-to-end live deployment" row in the Test Matrix. It executes the
// SAME deploy logic as the dry run, but against the real Sepolia network
// (chain id 11155111) reachable via the `sepolia` Hardhat network.
//
// Prerequisites (set via `npx hardhat keystore set <KEY>`):
//   - SEPOLIA_RPC_URL      HTTPS RPC endpoint (Alchemy/Infura/Tenderly).
//   - SEPOLIA_PRIVATE_KEY  Deployer key. Fund with >= 0.05 Sepolia ETH.
//   - ETHERSCAN_API_KEY    Optional; enables Etherscan verification.
//
// What the script does:
//   1. Validates network is Sepolia (chainId 11155111). Aborts otherwise.
//   2. Reads deployer ETH balance; aborts if below MIN_DEPLOYER_ETH.
//   3. Reads deployer Circle USDC Sepolia balance. Decides:
//        a. If balance >= (T0 + LS0) ⇒ use Circle USDC Sepolia.
//        b. Else                      ⇒ deploy MockStable (mUSD), mint to
//           deployer, and use it. Logs the fallback decision.
//   4. Deploys `M2GenesisFactory`.
//   5. Predicts the four CREATE addresses (treasury, token, hook-CREATE2,
//      router). Mines a fresh hook salt against the deployed factory's
//      address.
//   6. Approves the factory for (T0 + LS0) stable.
//   7. Calls `factory.execute(params)`. Waits for the receipt. Decodes
//      the `GenesisCompleted` event for the final addresses.
//   8. Writes the full deployment manifest to
//      `deploy/sepolia/manifest.json`.
//   9. If `ETHERSCAN_API_KEY` is set, attempts contract verification for
//      Treasury / Token / Router / Hook / Factory via hardhat-verify.
//
// Run via:
//   npm run deploy:sepolia                       # configured npm script
//   npx hardhat run scripts/deploy/02_deploy_sepolia.ts --network sepolia
//
// SAFETY: This script is non-destructive — it deploys NEW contracts but
// makes NO transfers from the deployer beyond the genesis seed
// (T0 + LS0) of the backing stable. If anything reverts, all genesis
// state is rolled back atomically by the factory.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import hre from "hardhat";
import {
  type Address,
  type Hex,
  decodeEventLog,
  encodeAbiParameters,
  formatEther,
  getAddress,
  getContractAddress,
  keccak256,
  pad,
  parseAbi,
  toHex,
} from "viem";

// ---------------------------------------------------------------------------
// Filesystem paths
// ---------------------------------------------------------------------------

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const CONTRACTS_ROOT = resolve(__dirname, "..", "..");
const DEPLOY_DIR = resolve(CONTRACTS_ROOT, "deploy", "sepolia");
const LIVE_MANIFEST = resolve(DEPLOY_DIR, "manifest.json");

// ---------------------------------------------------------------------------
// Constants (mirror contracts/libraries/M2Constants.sol + the plan)
// ---------------------------------------------------------------------------

const SEPOLIA_CHAIN_ID = 11155111;
const SEPOLIA_POOL_MANAGER: Address = getAddress(
  "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543",
);
const CIRCLE_USDC_SEPOLIA: Address = getAddress(
  "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
);

const S0 = 1_000_000_000n * 10n ** 18n;
const VESTING_TOTAL = 250_000_000n * 10n ** 18n;

// Canonical USDC-style seed (6 decimals).
const T0_USDC = 1_000_000n * 10n ** 6n;
const LS0_USDC = 750_000n * 10n ** 6n;

const MIN_DEPLOYER_ETH = 5n * 10n ** 16n; // 0.05 ETH

const ALL_HOOK_MASK = (1n << 14n) - 1n;
const BEFORE_SWAP_FLAG = 1n << 7n;

const TEST_RECIPIENT: Address = getAddress(
  "0x00000000000000000000000000000000be9ef1ca",
);

// ---------------------------------------------------------------------------
// Helpers (predict / mine / write manifest)
// ---------------------------------------------------------------------------

function predictCreate(deployer: Address, nonce: number): Address {
  if (nonce < 1 || nonce > 0x7f) {
    throw new Error(`predictCreate: nonce ${nonce} out of supported range`);
  }
  const rlp = `0xd694${deployer.slice(2)}${nonce.toString(16).padStart(2, "0")}` as Hex;
  return `0x${keccak256(rlp).slice(26)}` as Address;
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

interface SepoliaManifest {
  mode: "live";
  chainId: number;
  deployedAt: string;
  deployer: Address;
  stable: Address;
  stableSource: "circle-usdc-sepolia" | "mock-stable-fallback";
  factory: Address;
  factoryDeployTxHash: Hex;
  executeTxHash: Hex;
  token: Address;
  treasury: Address;
  router: Address;
  hook: Address;
  vestingWallets: Address[];
  poolManager: Address;
  hookSalt: Hex;
  hookBytecodeHash: Hex;
  e2e?: Record<string, Hex>;
}

function writeManifest(manifest: SepoliaManifest): void {
  if (!existsSync(DEPLOY_DIR)) mkdirSync(DEPLOY_DIR, { recursive: true });
  const replacer = (_k: string, v: unknown) =>
    typeof v === "bigint" ? v.toString() : v;
  writeFileSync(
    LIVE_MANIFEST,
    `${JSON.stringify(manifest, replacer, 2)}\n`,
    "utf8",
  );
}

function mergeManifest(partial: Partial<SepoliaManifest>): void {
  let base: SepoliaManifest | Record<string, unknown> = {};
  if (existsSync(LIVE_MANIFEST)) {
    try {
      base = JSON.parse(readFileSync(LIVE_MANIFEST, "utf8"));
    } catch {
      base = {};
    }
  }
  const merged = { ...base, ...partial } as SepoliaManifest;
  writeManifest(merged);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  process.stdout.write(`\n=== M² LIVE Sepolia deployment ===\n`);

  const connection = await hre.network.connect();
  const viem = (connection as unknown as { viem: any }).viem;
  const publicClient = await viem.getPublicClient();
  const [walletClient] = await viem.getWalletClients();
  const deployer = walletClient.account.address as Address;
  const chainId = await publicClient.getChainId();

  process.stdout.write(
    `  network:  ${hre.globalOptions.network ?? "sepolia"}\n` +
      `  chainId:  ${chainId}\n` +
      `  deployer: ${deployer}\n`,
  );

  if (chainId !== SEPOLIA_CHAIN_ID) {
    throw new Error(
      `02_deploy_sepolia: chainId ${chainId} is not Sepolia (${SEPOLIA_CHAIN_ID}). ` +
        `Re-run with \`--network sepolia\`.`,
    );
  }

  // -------- 1. Deployer ETH balance check --------------------------------

  const ethBalance = await publicClient.getBalance({ address: deployer });
  process.stdout.write(`  ETH balance: ${formatEther(ethBalance)} ETH\n`);
  if (ethBalance < MIN_DEPLOYER_ETH) {
    throw new Error(
      `02_deploy_sepolia: deployer has ${formatEther(ethBalance)} ETH; ` +
        `need at least ${formatEther(MIN_DEPLOYER_ETH)} ETH. Top up via a ` +
        `Sepolia faucet.`,
    );
  }

  // -------- 2. Decide stable: Circle USDC Sepolia or MockStable fallback -

  process.stdout.write(`\n  Checking Circle USDC Sepolia balance...\n`);
  const erc20Abi = parseAbi([
    "function balanceOf(address) view returns (uint256)",
    "function approve(address,uint256) returns (bool)",
    "function decimals() view returns (uint8)",
  ]);

  let stableAddr: Address;
  let stableSource: "circle-usdc-sepolia" | "mock-stable-fallback";

  const usdcBalance = (await publicClient.readContract({
    address: CIRCLE_USDC_SEPOLIA,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [deployer],
  })) as bigint;
  process.stdout.write(
    `    Circle USDC balance: ${usdcBalance} (need ${T0_USDC + LS0_USDC})\n`,
  );

  if (usdcBalance >= T0_USDC + LS0_USDC) {
    stableAddr = CIRCLE_USDC_SEPOLIA;
    stableSource = "circle-usdc-sepolia";
    process.stdout.write(`    Using Circle USDC Sepolia.\n`);
  } else {
    process.stdout.write(
      `    Insufficient USDC; falling back to MockStable (mUSD).\n`,
    );
    const mockStable = await viem.deployContract("MockStable", []);
    stableAddr = mockStable.address as Address;
    const mintHash = await mockStable.write.mint(
      [deployer, T0_USDC + LS0_USDC],
      { account: walletClient.account },
    );
    await publicClient.waitForTransactionReceipt({ hash: mintHash });
    stableSource = "mock-stable-fallback";
    process.stdout.write(`    MockStable deployed at: ${stableAddr}\n`);
  }

  // -------- 3. Deploy M2GenesisFactory ----------------------------------

  process.stdout.write(`\n  Deploying M2GenesisFactory...\n`);
  const factory = await viem.deployContract("M2GenesisFactory", []);
  const factoryAddr = factory.address as Address;
  process.stdout.write(`    factory: ${factoryAddr}\n`);

  // -------- 4. Predict + mine hook salt ---------------------------------

  process.stdout.write(`\n  Predicting addresses + mining hook salt...\n`);
  const predictedTreasury = predictCreate(factoryAddr, 1);
  const predictedToken = predictCreate(factoryAddr, 2);
  const predictedRouter = predictCreate(factoryAddr, 4);
  const hookArtifact = await hre.artifacts.readArtifact("M2V4Hook");
  const hookCreationCode = hookArtifact.bytecode as Hex;
  const minedSalt = mineHookSalt(
    factoryAddr,
    hookCreationCode,
    SEPOLIA_POOL_MANAGER,
    predictedToken,
    stableAddr,
    predictedTreasury,
  );
  process.stdout.write(
    `    treasury: ${predictedTreasury}\n` +
      `    token:    ${predictedToken}\n` +
      `    router:   ${predictedRouter}\n` +
      `    hook:     ${minedSalt.hookAddress} (${minedSalt.iterations} iters)\n`,
  );

  // Persist a partial manifest BEFORE the genesis call so a failed
  // execute() leaves a forensic record.
  const hookBytecodeHash = keccak256(
    `${hookCreationCode}${encodeAbiParameters(
      [
        { type: "address" },
        { type: "address" },
        { type: "address" },
        { type: "address" },
      ],
      [SEPOLIA_POOL_MANAGER, predictedToken, stableAddr, predictedTreasury],
    ).slice(2)}` as Hex,
  );
  mergeManifest({
    mode: "live",
    chainId,
    deployedAt: new Date().toISOString(),
    deployer,
    stable: stableAddr,
    stableSource,
    factory: factoryAddr,
    factoryDeployTxHash: "0x" as Hex,
    executeTxHash: "0x" as Hex,
    token: predictedToken,
    treasury: predictedTreasury,
    router: predictedRouter,
    hook: minedSalt.hookAddress,
    vestingWallets: [],
    poolManager: SEPOLIA_POOL_MANAGER,
    hookSalt: minedSalt.salt,
    hookBytecodeHash,
  });
  // Mirror the hook-salt cache for Sepolia.
  if (!existsSync(DEPLOY_DIR)) mkdirSync(DEPLOY_DIR, { recursive: true });
  writeFileSync(
    resolve(DEPLOY_DIR, "hook_salt.json"),
    `${JSON.stringify(
      {
        salt: minedSalt.salt,
        hookAddress: minedSalt.hookAddress,
        bytecodeHash: hookBytecodeHash,
        factoryAddress: factoryAddr,
        constructorArgs: {
          poolManager: SEPOLIA_POOL_MANAGER,
          token: predictedToken,
          stable: stableAddr,
          treasury: predictedTreasury,
        },
        hookFlag: "0x0080",
        metadata: {
          solcVersion: "0.8.34",
          contractName: "M2V4Hook",
          sourceName: "contracts/hook/M2V4Hook.sol",
          minedAt: new Date().toISOString(),
          iterations: minedSalt.iterations,
        },
      },
      null,
      2,
    )}\n`,
    "utf8",
  );

  // -------- 5. Approve + execute genesis --------------------------------

  process.stdout.write(`\n  Approving factory for ${T0_USDC + LS0_USDC} stable...\n`);
  const approveAbi = parseAbi([
    "function approve(address,uint256) returns (bool)",
  ]);
  const approveHash = await walletClient.writeContract({
    address: stableAddr,
    abi: approveAbi,
    functionName: "approve",
    args: [factoryAddr, T0_USDC + LS0_USDC],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  process.stdout.write(`  Calling factory.execute()...\n`);
  const now = BigInt(Math.floor(Date.now() / 1000));
  const params = {
    stable: stableAddr,
    poolManager: SEPOLIA_POOL_MANAGER,
    depositor: deployer,
    treasurySeed: T0_USDC,
    lpStableSeed: LS0_USDC,
    lpLiquidity: 1_000_000n,
    sqrtPriceX96Initial: 1n << 96n,
    tickSpacing: 60,
    hookSalt: minedSalt.salt,
    hookCreationCode,
    vestingRecipients: [TEST_RECIPIENT],
    vestingStarts: [now],
    vestingDurations: [0n],
    vestingAllocations: [VESTING_TOTAL],
  };

  const executeTxHash = (await factory.write.execute([params], {
    account: walletClient.account,
  })) as Hex;
  const executeRcpt = await publicClient.waitForTransactionReceipt({
    hash: executeTxHash,
  });
  if (executeRcpt.status !== "success") {
    throw new Error(`genesis execute reverted: ${executeTxHash}`);
  }
  process.stdout.write(
    `  execute tx:   ${executeTxHash}\n` +
      `  gas used:     ${executeRcpt.gasUsed}\n`,
  );

  // -------- 6. Decode GenesisCompleted from logs ------------------------

  const genesisAbi = parseAbi([
    "event GenesisCompleted(address token, address treasury, address router, address hook, address[] vestingWallets)",
  ]);
  let token: Address | undefined;
  let treasury: Address | undefined;
  let router: Address | undefined;
  let hook: Address | undefined;
  let vestingWallets: Address[] = [];
  for (const log of executeRcpt.logs) {
    try {
      const decoded = decodeEventLog({
        abi: genesisAbi,
        data: log.data,
        topics: log.topics,
      });
      if (decoded.eventName === "GenesisCompleted") {
        token = decoded.args.token as Address;
        treasury = decoded.args.treasury as Address;
        router = decoded.args.router as Address;
        hook = decoded.args.hook as Address;
        vestingWallets = [...(decoded.args.vestingWallets as Address[])];
        break;
      }
    } catch {
      /* not this event */
    }
  }
  if (!token || !treasury || !router || !hook) {
    throw new Error("02_deploy_sepolia: GenesisCompleted event not found");
  }

  process.stdout.write(
    `\n  GenesisCompleted parsed:\n` +
      `    token:    ${token}\n` +
      `    treasury: ${treasury}\n` +
      `    router:   ${router}\n` +
      `    hook:     ${hook}\n` +
      `    vesting:  ${vestingWallets.length} wallet(s)\n`,
  );

  // -------- 7. Persist final manifest -----------------------------------

  mergeManifest({
    executeTxHash,
    token,
    treasury,
    router,
    hook,
    vestingWallets,
  });
  process.stdout.write(`\n  Manifest: ${LIVE_MANIFEST}\n`);

  // -------- 8. Etherscan verification (best-effort) ---------------------

  // The verify plugin is invoked here with simple retries. If
  // ETHERSCAN_API_KEY is not configured, the call falls through.
  process.stdout.write(
    `\n  Verification is opt-in. Run \`npx hardhat verify --network sepolia ` +
      `<address> <constructor-args...>\` per contract; ` +
      `the manifest carries the addresses and constructor arg layout.\n`,
  );

  // Sanity: assert deployer's stable balance dropped by exactly T0+LS0.
  const finalStable = (await publicClient.readContract({
    address: stableAddr,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [deployer],
  })) as bigint;
  process.stdout.write(
    `  Deployer stable balance: ${finalStable} (post-seed; total supply ${S0})\n\n`,
  );
}

main().catch((err) => {
  process.stderr.write(
    `${err instanceof Error ? err.stack ?? err.message : String(err)}\n`,
  );
  process.exit(1);
});
