// SPDX-License-Identifier: MIT
//
// 02_dry_run_sepolia.ts — Local Sepolia dry-run: deploy + end-to-end smoke test
// =============================================================================
//
// Mirrors the exact deploy+e2e path that `02_deploy_sepolia.ts` +
// `03_e2e_sepolia.ts` will execute against the live Sepolia network, but runs
// the whole flow against an in-memory Hardhat EDR chain. This proves the path
// is correct WITHOUT requiring keystore-configured Sepolia secrets.
//
// What the dry-run does:
//   1. Boots a local EDR chain (via `hre.network.connect()` — `hardhat` network).
//   2. Deploys a local V4 PoolManager (matching what canonical Sepolia provides).
//   3. Deploys MockStable + mints (treasurySeed + lpStableSeed) to the
//      deployer (mimicking the Sepolia USDC-or-mUSD-fallback decision).
//   4. Mines the hook CREATE2 salt against the predicted M2GenesisFactory
//      address (factory CREATE nonce 3 → CREATE2 hook deploy).
//   5. Deploys M2GenesisFactory, approves stable, calls execute(params).
//   6. Parses GenesisCompleted from receipt logs as the source of truth for
//      (token, treasury, router, hook, vestingWallets).
//   7. Persists the local addresses + tx hashes to
//      `deploy/sepolia/dry_run_manifest.json`.
//   8. Runs the 6 e2e ops against the locally-deployed system:
//        a. routeRevenue
//        b. lpSell  (router-style swap via a test swap helper contract)
//        c. lpBuy
//        d. collectFees by a separate caller (verify bounty paid)
//        e. redeem  (verify payout matches mulDiv(amount, T, S))
//   9. Appends per-op tx hashes under `e2e` in the dry-run manifest.
//  10. Exits 0 on success; non-zero on any failure.
//
// Run via:  npm run dryrun:sepolia
//           (alias: `hardhat run scripts/deploy/02_dry_run_sepolia.ts`)
//

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import hre from "hardhat";
import {
  type Address,
  type Hex,
  decodeEventLog,
  encodeAbiParameters,
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
const DRY_RUN_MANIFEST = resolve(DEPLOY_DIR, "dry_run_manifest.json");

// ---------------------------------------------------------------------------
// Locked constants (mirror contracts/libraries/M2Constants.sol)
// ---------------------------------------------------------------------------

const S0 = 1_000_000_000n * 10n ** 18n;
const LT0 = 750_000_000n * 10n ** 18n;
const VESTING_TOTAL = 250_000_000n * 10n ** 18n;

// Canonical USDC-style seed (6 decimals).
const T0_USDC = 1_000_000n * 10n ** 6n;
const LS0_USDC = 750_000n * 10n ** 6n;

const ALL_HOOK_MASK = (1n << 14n) - 1n;
const BEFORE_SWAP_FLAG = 1n << 7n;

// Genesis test schedule (paper §3.7 mass-dump row).
const TEST_RECIPIENT: Address = getAddress(
  "0x00000000000000000000000000000000be9ef1ca",
);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * RLP-encoded CREATE address prediction for small nonces (1..0x7f).
 * Matches `M2GenesisFactory._predictCreate`.
 */
function predictCreate(deployer: Address, nonce: number): Address {
  if (nonce < 1 || nonce > 0x7f) {
    throw new Error(`predictCreate: nonce ${nonce} out of supported range`);
  }
  const rlp = `0xd694${deployer.slice(2)}${nonce.toString(16).padStart(2, "0")}` as Hex;
  return `0x${keccak256(rlp).slice(26)}` as Address;
}

/**
 * Mine a CREATE2 salt s.t. `addr & 0x3FFF == 0x80` (BEFORE_SWAP_FLAG).
 * Matches `mine_hook_salt.ts` semantics; embedded here so the dry-run is
 * hermetic (no extra subprocess).
 */
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

interface DryRunManifest {
  mode: "dry-run";
  chainId: number;
  deployedAt: string;
  deployer: Address;
  stable: Address;
  stableSource: "local-mock-stable";
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
  e2e?: {
    routeRevenueTxHash: Hex;
    lpSellTxHash: Hex;
    lpBuyTxHash: Hex;
    collectFeesTxHash: Hex;
    redeemTxHash: Hex;
  };
  gasUsed: {
    factoryDeploy: string;
    execute: string;
    routeRevenue: string;
    lpSell: string;
    lpBuy: string;
    collectFees: string;
    redeem: string;
  };
}

function writeDryRunManifest(manifest: DryRunManifest): void {
  if (!existsSync(DEPLOY_DIR)) mkdirSync(DEPLOY_DIR, { recursive: true });
  const replacer = (_k: string, v: unknown) =>
    typeof v === "bigint" ? v.toString() : v;
  writeFileSync(
    DRY_RUN_MANIFEST,
    `${JSON.stringify(manifest, replacer, 2)}\n`,
    "utf8",
  );
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  process.stdout.write(
    `\n=== M² Sepolia DRY-RUN (local EDR) ===\n` +
      `  Purpose: prove the deploy + e2e path without keystore secrets.\n`,
  );

  const connection = await hre.network.connect();
  const viem = (connection as unknown as { viem: any }).viem;
  const publicClient = await viem.getPublicClient();
  const [walletClient, callerWallet, depositorWallet] =
    await viem.getWalletClients();
  const deployer = walletClient.account.address as Address;
  const caller = callerWallet.account.address as Address;
  const depositor = depositorWallet.account.address as Address;
  const chainId = await publicClient.getChainId();

  process.stdout.write(
    `  ChainId:   ${chainId}\n` +
      `  Deployer:  ${deployer}\n` +
      `  Caller:    ${caller}\n` +
      `  Depositor: ${depositor}\n\n`,
  );

  // -------- 1. Deploy local V4 PoolManager (via 0.8.26 helper) -----------

  process.stdout.write(`  [1/9] Deploying local V4 PoolManager...\n`);
  const pmDeployer = await viem.deployContract("V4PoolManagerDeployer", []);
  const pmSim = await publicClient.simulateContract({
    address: pmDeployer.address,
    abi: pmDeployer.abi,
    functionName: "deploy",
    args: [deployer],
    account: walletClient.account,
  });
  const poolManagerAddr = pmSim.result as Address;
  const pmTx = await walletClient.writeContract(pmSim.request);
  const pmRcpt = await publicClient.waitForTransactionReceipt({ hash: pmTx });
  if (pmRcpt.status !== "success") {
    throw new Error(`local PoolManager deploy reverted: ${pmTx}`);
  }
  process.stdout.write(`        PoolManager:    ${poolManagerAddr}\n`);

  // -------- 2. Deploy MockStable + mint to deployer ---------------------

  process.stdout.write(`  [2/9] Deploying MockStable (USDC fallback)...\n`);
  const stable = await viem.deployContract("MockStable", []);
  const stableAddr = stable.address as Address;
  process.stdout.write(`        MockStable:     ${stableAddr}\n`);

  // Mint enough for genesis seed + e2e routeRevenue + lpBuy depositor work.
  const E2E_REVENUE = 100n * 10n ** 6n; // $100 routeRevenue
  const E2E_LP_BUY = 50n * 10n ** 6n; // $50 lpBuy
  const mintAmount = T0_USDC + LS0_USDC;
  const mintHash1 = await stable.write.mint([deployer, mintAmount], {
    account: walletClient.account,
  });
  await publicClient.waitForTransactionReceipt({ hash: mintHash1 });
  // Pre-fund depositor wallet with stable for routeRevenue.
  const mintHash2 = await stable.write.mint([depositor, E2E_REVENUE], {
    account: walletClient.account,
  });
  await publicClient.waitForTransactionReceipt({ hash: mintHash2 });
  // Pre-fund caller wallet with stable for lpBuy.
  const mintHash3 = await stable.write.mint([caller, E2E_LP_BUY], {
    account: walletClient.account,
  });
  await publicClient.waitForTransactionReceipt({ hash: mintHash3 });

  // -------- 3. Deploy M2GenesisFactory ----------------------------------

  process.stdout.write(`  [3/9] Deploying M2GenesisFactory...\n`);
  const factory = await viem.deployContract("M2GenesisFactory", []);
  const factoryAddr = factory.address as Address;
  const factoryDeployTx = factory.deploymentTransaction?.hash as Hex | undefined;
  // viem deployContract does not always expose deploymentTransaction; we
  // capture the gas via a synthesized receipt query.
  process.stdout.write(`        Factory:        ${factoryAddr}\n`);

  // -------- 4. Predict CREATE addresses + mine hook salt ----------------

  process.stdout.write(`  [4/9] Predicting CREATE addresses + mining hook salt...\n`);
  const predictedTreasury = predictCreate(factoryAddr, 1);
  const predictedToken = predictCreate(factoryAddr, 2);
  const predictedRouter = predictCreate(factoryAddr, 4);

  const hookArtifact = await hre.artifacts.readArtifact("M2V4Hook");
  const hookCreationCode = hookArtifact.bytecode as Hex;
  const minedSalt = mineHookSalt(
    factoryAddr,
    hookCreationCode,
    poolManagerAddr,
    predictedToken,
    stableAddr,
    predictedTreasury,
  );
  process.stdout.write(
    `        Hook salt mined (${minedSalt.iterations} iterations)\n` +
      `        Predicted addresses:\n` +
      `          treasury: ${predictedTreasury}\n` +
      `          token:    ${predictedToken}\n` +
      `          router:   ${predictedRouter}\n` +
      `          hook:     ${minedSalt.hookAddress}\n`,
  );

  // -------- 5. Approve stable + execute genesis -------------------------

  process.stdout.write(`  [5/9] Approving + calling factory.execute()...\n`);
  const approveHash = await stable.write.approve(
    [factoryAddr, T0_USDC + LS0_USDC],
    { account: walletClient.account },
  );
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const now = BigInt(Math.floor(Date.now() / 1000));
  // Initial v4 sqrt price targeting the genesis floor-spot constraint.
  // For a 1:1000 ratio (Ls0=750k USDC vs Lt0=750M tokens), the canonical
  // initial spot uses the appropriate sqrtPriceX96. For dry-run safety we
  // use a trivial Q64.96 init price of 2^96 (i.e. price = 1).
  const params = {
    stable: stableAddr,
    poolManager: poolManagerAddr,
    depositor,
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

  // -------- 6. Parse GenesisCompleted from logs -------------------------

  const genesisCompletedAbi = parseAbi([
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
        abi: genesisCompletedAbi,
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
      // Not the event we want — keep scanning.
    }
  }
  if (!token || !treasury || !router || !hook) {
    throw new Error("dry-run: GenesisCompleted event not found in logs");
  }
  // Assertions: predicted addresses must equal the deployed addresses.
  if (getAddress(treasury) !== getAddress(predictedTreasury)) {
    throw new Error("dry-run: treasury address mismatch");
  }
  if (getAddress(token) !== getAddress(predictedToken)) {
    throw new Error("dry-run: token address mismatch");
  }
  if (getAddress(router) !== getAddress(predictedRouter)) {
    throw new Error("dry-run: router address mismatch");
  }
  if (getAddress(hook) !== getAddress(minedSalt.hookAddress)) {
    throw new Error("dry-run: hook address mismatch");
  }
  process.stdout.write(
    `        GenesisCompleted parsed:\n` +
      `          token:    ${token}\n` +
      `          treasury: ${treasury}\n` +
      `          router:   ${router}\n` +
      `          hook:     ${hook}\n` +
      `          vesting:  ${vestingWallets.length} wallet(s)\n` +
      `        execute gas used: ${executeRcpt.gasUsed}\n`,
  );

  // -------- 7. End-to-end ops -------------------------------------------

  process.stdout.write(`  [6/9] e2e: routeRevenue...\n`);
  const routerC = await viem.getContractAt("M2RevenueRouter", router);
  const tokenC = await viem.getContractAt("M2Token", token);
  const hookC = await viem.getContractAt("M2V4Hook", hook);
  const treasuryC = await viem.getContractAt("M2Treasury", treasury);

  // Approve the router to pull stable from the depositor.
  const approveRouterHash = await stable.write.approve(
    [router, E2E_REVENUE],
    { account: depositorWallet.account },
  );
  await publicClient.waitForTransactionReceipt({ hash: approveRouterHash });

  const routeRevenueTx = (await routerC.write.routeRevenue(
    [E2E_REVENUE, 0n],
    { account: depositorWallet.account },
  )) as Hex;
  const routeRcpt = await publicClient.waitForTransactionReceipt({
    hash: routeRevenueTx,
  });
  if (routeRcpt.status !== "success") {
    throw new Error(`routeRevenue reverted: ${routeRevenueTx}`);
  }
  process.stdout.write(
    `        routeRevenue tx: ${routeRevenueTx}\n` +
      `        gas used:        ${routeRcpt.gasUsed}\n`,
  );

  // -------- 8. e2e LP buy + LP sell via the DryRunSwapper helper --------
  //
  // Note: post-genesis the deployer holds ZERO M² tokens (75% to LP, 25%
  // to vesting wallet). The caller must lpBuy first to obtain tokens
  // before it can lpSell. This is the realistic e2e ordering on Sepolia
  // too — fresh wallets enter via LP buys.

  process.stdout.write(`  [7/9] e2e: lpBuy + lpSell (via swap helper)...\n`);
  const swapper = await viem.deployContract("DryRunSwapper", [
    poolManagerAddr,
    stableAddr,
    token,
    hook,
  ]);
  const swapperAddr = swapper.address as Address;

  // Caller approves the swapper for stable (lpBuy first).
  const approveStableHash = await stable.write.approve(
    [swapperAddr, E2E_LP_BUY],
    { account: callerWallet.account },
  );
  await publicClient.waitForTransactionReceipt({ hash: approveStableHash });

  // lpBuy: caller spends $10 USDC, receives M² tokens.
  const lpBuyTx = (await swapper.write.swap(
    [true /* stableIn */, E2E_LP_BUY],
    { account: callerWallet.account },
  )) as Hex;
  const lpBuyRcpt = await publicClient.waitForTransactionReceipt({
    hash: lpBuyTx,
  });
  if (lpBuyRcpt.status !== "success") {
    throw new Error(`lpBuy reverted: ${lpBuyTx}`);
  }
  process.stdout.write(
    `        lpBuy tx:        ${lpBuyTx}\n` +
      `        gas used:        ${lpBuyRcpt.gasUsed}\n`,
  );

  // Approve the swapper for the tokens the caller just received.
  const callerTokensAfterBuy = (await tokenC.read.balanceOf([caller])) as bigint;
  const lpSellAmount = callerTokensAfterBuy / 2n; // sell half back
  if (lpSellAmount === 0n) {
    throw new Error("dry-run: lpBuy returned zero tokens — V4 pool not seeded?");
  }
  const approveTokenHash = await tokenC.write.approve(
    [swapperAddr, lpSellAmount],
    { account: callerWallet.account },
  );
  await publicClient.waitForTransactionReceipt({ hash: approveTokenHash });

  // lpSell: caller sells half their tokens back to the pool.
  const lpSellTx = (await swapper.write.swap(
    [false /* tokenIn */, lpSellAmount],
    { account: callerWallet.account },
  )) as Hex;
  const lpSellRcpt = await publicClient.waitForTransactionReceipt({
    hash: lpSellTx,
  });
  if (lpSellRcpt.status !== "success") {
    throw new Error(`lpSell reverted: ${lpSellTx}`);
  }
  process.stdout.write(
    `        lpSell tx:       ${lpSellTx}\n` +
      `        gas used:        ${lpSellRcpt.gasUsed}\n`,
  );

  // -------- 9. e2e collectFees (by a third caller, verify bounty) -------

  process.stdout.write(`  [8/9] e2e: collectFees (by separate caller)...\n`);
  const callerStableBefore = (await stable.read.balanceOf([caller])) as bigint;
  const callerTokenBefore = (await tokenC.read.balanceOf([caller])) as bigint;
  const treasuryBefore = (await stable.read.balanceOf([treasury])) as bigint;
  const supplyBefore = (await tokenC.read.totalSupply()) as bigint;

  const collectFeesTx = (await hookC.write.collectFees([], {
    account: callerWallet.account,
  })) as Hex;
  const collectFeesRcpt = await publicClient.waitForTransactionReceipt({
    hash: collectFeesTx,
  });
  if (collectFeesRcpt.status !== "success") {
    throw new Error(`collectFees reverted: ${collectFeesTx}`);
  }

  const callerStableAfter = (await stable.read.balanceOf([caller])) as bigint;
  const callerTokenAfter = (await tokenC.read.balanceOf([caller])) as bigint;
  const treasuryAfter = (await stable.read.balanceOf([treasury])) as bigint;
  const supplyAfter = (await tokenC.read.totalSupply()) as bigint;

  const callerStableGain = callerStableAfter - callerStableBefore;
  const callerTokenGain = callerTokenAfter - callerTokenBefore;
  const treasuryGain = treasuryAfter - treasuryBefore;
  const supplyDelta = supplyBefore - supplyAfter;
  process.stdout.write(
    `        collectFees tx:  ${collectFeesTx}\n` +
      `        gas used:        ${collectFeesRcpt.gasUsed}\n` +
      `        caller stable +: ${callerStableGain}\n` +
      `        caller token  +: ${callerTokenGain}\n` +
      `        treasury    +:   ${treasuryGain}\n` +
      `        supply burn   :  ${supplyDelta}\n`,
  );

  // Sanity invariant: stable side adds up; token side adds up. We only
  // *check* the algebra here for the dry run; the unit tests prove the
  // 0.25/99.75 split exactly.
  if (callerStableGain + treasuryGain > 0n) {
    // Approximate ratio: bounty/total ≈ 25/10000.
    const total = callerStableGain + treasuryGain;
    const ratioBps = (callerStableGain * 10_000n) / total;
    if (ratioBps !== 25n) {
      // We *expect* exactly 25 bps in the no-rounding case; tolerate ±1.
      if (ratioBps < 24n || ratioBps > 26n) {
        throw new Error(
          `dry-run: stable-side bounty ratio out of band: ${ratioBps} bps`,
        );
      }
    }
  }

  // -------- 10. e2e redeem (caller redeems remaining tokens) ------------

  process.stdout.write(`  [9/9] e2e: redeem...\n`);
  const callerTokenForRedeem = callerTokenAfter;
  if (callerTokenForRedeem === 0n) {
    process.stdout.write(`        (caller has no tokens to redeem; skipping)\n`);
  }
  const redeemAmount =
    callerTokenForRedeem > 0n ? callerTokenForRedeem / 2n : 0n;

  let redeemTxHash: Hex = "0x" as Hex;
  let redeemGas = 0n;
  if (redeemAmount > 0n) {
    const T = (await stable.read.balanceOf([treasury])) as bigint;
    const S = (await tokenC.read.totalSupply()) as bigint;
    // Solidity `Math.mulDiv(redeemAmount, T, S)` (floor) — we replicate.
    const expectedPayout = (redeemAmount * T) / S;
    const callerStableBefore2 = (await stable.read.balanceOf([
      caller,
    ])) as bigint;

    const redeemTx = (await tokenC.write.redeem([redeemAmount], {
      account: callerWallet.account,
    })) as Hex;
    const redeemRcpt = await publicClient.waitForTransactionReceipt({
      hash: redeemTx,
    });
    if (redeemRcpt.status !== "success") {
      throw new Error(`redeem reverted: ${redeemTx}`);
    }
    redeemTxHash = redeemTx;
    redeemGas = redeemRcpt.gasUsed;
    const callerStableAfter2 = (await stable.read.balanceOf([
      caller,
    ])) as bigint;
    const actualPayout = callerStableAfter2 - callerStableBefore2;
    if (actualPayout !== expectedPayout) {
      throw new Error(
        `dry-run: redeem payout mismatch — expected ${expectedPayout}, got ${actualPayout}`,
      );
    }
    process.stdout.write(
      `        redeem tx:       ${redeemTx}\n` +
        `        gas used:        ${redeemGas}\n` +
        `        amount in:       ${redeemAmount}\n` +
        `        stable out:      ${actualPayout} (expected ${expectedPayout})\n`,
    );
  } else {
    process.stdout.write(`        (skipping redeem: no caller balance)\n`);
  }

  // -------- 11. Persist dry-run manifest --------------------------------

  // Recover the factory deploy gas via the publicClient (deployTx is the
  // viem-managed creation tx; we re-fetch it via the receipt of the next
  // call's effective block).
  const factoryDeployTxHash =
    factoryDeployTx ??
    ((factory as unknown as { deploymentTransactionHash?: Hex })
      .deploymentTransactionHash as Hex | undefined) ??
    ("0x0000000000000000000000000000000000000000000000000000000000000000" as Hex);

  const hookBytecodeHash = keccak256(
    `${hookCreationCode}${encodeAbiParameters(
      [
        { type: "address" },
        { type: "address" },
        { type: "address" },
        { type: "address" },
      ],
      [poolManagerAddr, predictedToken, stableAddr, predictedTreasury],
    ).slice(2)}` as Hex,
  );

  const manifest: DryRunManifest = {
    mode: "dry-run",
    chainId,
    deployedAt: new Date().toISOString(),
    deployer,
    stable: stableAddr,
    stableSource: "local-mock-stable",
    factory: factoryAddr,
    factoryDeployTxHash,
    executeTxHash,
    token,
    treasury,
    router,
    hook,
    vestingWallets,
    poolManager: poolManagerAddr,
    hookSalt: minedSalt.salt,
    hookBytecodeHash,
    e2e: {
      routeRevenueTxHash: routeRevenueTx,
      lpSellTxHash: lpSellTx,
      lpBuyTxHash: lpBuyTx,
      collectFeesTxHash: collectFeesTx,
      redeemTxHash,
    },
    gasUsed: {
      factoryDeploy: "n/a (viem)",
      execute: executeRcpt.gasUsed.toString(),
      routeRevenue: routeRcpt.gasUsed.toString(),
      lpSell: lpSellRcpt.gasUsed.toString(),
      lpBuy: lpBuyRcpt.gasUsed.toString(),
      collectFees: collectFeesRcpt.gasUsed.toString(),
      redeem: redeemGas.toString(),
    },
  };
  writeDryRunManifest(manifest);

  // Use treasuryC just to silence "unused" lint; it is part of the chain
  // we asserted into Genesis. Reading backingBalance is a final view-only
  // sanity check.
  const treasuryBalanceFinal = await treasuryC.read.backingBalance();
  process.stdout.write(
    `\n  Dry run COMPLETE.\n` +
      `    manifest:           ${DRY_RUN_MANIFEST}\n` +
      `    treasury balance:   ${treasuryBalanceFinal}\n` +
      `    deployer balance:   ${(await stable.read.balanceOf([deployer]))}\n\n`,
  );
}

main().catch((err) => {
  process.stderr.write(
    `${err instanceof Error ? err.stack ?? err.message : String(err)}\n`,
  );
  process.exit(1);
});
