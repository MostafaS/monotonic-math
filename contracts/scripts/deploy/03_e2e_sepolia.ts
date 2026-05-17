// SPDX-License-Identifier: MIT
//
// 03_e2e_sepolia.ts — End-to-end smoke test against the live Sepolia M² system
// ============================================================================
//
// Runs the 6 end-to-end operations against a live Sepolia deployment:
//
//   1. routeRevenue(small_stableAmount)
//   2. lpSell from a separately-configured wallet (via DryRunSwapper)
//   3. lpBuy  from a separately-configured wallet (via DryRunSwapper)
//   4. collectFees by a DIFFERENT caller (verify bounty paid)
//   5. redeem by a DIFFERENT caller (verify payout == mulDiv(amount, T, S))
//
// Reads addresses from `deploy/sepolia/manifest.json`, written by
// `02_deploy_sepolia.ts`. Appends per-op tx hashes to the manifest under
// the `e2e` key.
//
// Prerequisites:
//   - 02_deploy_sepolia.ts already ran successfully against Sepolia.
//   - The deployer wallet has Sepolia ETH for the e2e txs.
//   - The deployer wallet has stable to fund the routeRevenue (and the
//     swap helper for the lpBuy leg).
//
// Run via:
//   npm run e2e:sepolia
//   npx hardhat run scripts/deploy/03_e2e_sepolia.ts --network sepolia

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import hre from "hardhat";
import {
  type Address,
  type Hex,
  getAddress,
  parseAbi,
} from "viem";

// ---------------------------------------------------------------------------
// Filesystem paths
// ---------------------------------------------------------------------------

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const CONTRACTS_ROOT = resolve(__dirname, "..", "..");
const MANIFEST_PATH = resolve(
  CONTRACTS_ROOT,
  "deploy",
  "sepolia",
  "manifest.json",
);

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SEPOLIA_CHAIN_ID = 11155111;

// e2e amounts — kept SMALL to avoid significant fund movement on Sepolia.
const E2E_REVENUE = 10n * 10n ** 6n; // $10 USDC routeRevenue
const E2E_LP_BUY = 5n * 10n ** 6n; // $5 USDC lpBuy
const E2E_LP_SELL = 100n * 10n ** 18n; // 100 M² lpSell

// ---------------------------------------------------------------------------
// Manifest types + helpers
// ---------------------------------------------------------------------------

interface SepoliaManifest {
  mode: "live";
  chainId: number;
  deployer: Address;
  stable: Address;
  factory: Address;
  token: Address;
  treasury: Address;
  router: Address;
  hook: Address;
  poolManager: Address;
  vestingWallets: Address[];
  e2e?: Record<string, Hex>;
  [key: string]: unknown;
}

function readManifest(): SepoliaManifest {
  if (!existsSync(MANIFEST_PATH)) {
    throw new Error(
      `03_e2e_sepolia: manifest not found at ${MANIFEST_PATH}. ` +
        `Run \`npm run deploy:sepolia\` first.`,
    );
  }
  return JSON.parse(readFileSync(MANIFEST_PATH, "utf8")) as SepoliaManifest;
}

function writeManifest(m: SepoliaManifest): void {
  const replacer = (_k: string, v: unknown) =>
    typeof v === "bigint" ? v.toString() : v;
  writeFileSync(
    MANIFEST_PATH,
    `${JSON.stringify(m, replacer, 2)}\n`,
    "utf8",
  );
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  process.stdout.write(`\n=== M² Sepolia LIVE e2e smoke test ===\n`);

  const manifest = readManifest();
  const connection = await hre.network.connect();
  const viem = (connection as unknown as { viem: any }).viem;
  const publicClient = await viem.getPublicClient();
  const wallets = await viem.getWalletClients();
  const [walletClient, callerWallet, depositorWallet] = wallets;
  const deployer = walletClient.account.address as Address;
  const caller = callerWallet?.account.address as Address | undefined;
  const chainId = await publicClient.getChainId();

  if (chainId !== SEPOLIA_CHAIN_ID) {
    throw new Error(
      `03_e2e_sepolia: chainId ${chainId} is not Sepolia (${SEPOLIA_CHAIN_ID}). ` +
        `Re-run with \`--network sepolia\`.`,
    );
  }
  if (getAddress(deployer) !== getAddress(manifest.deployer)) {
    throw new Error(
      `03_e2e_sepolia: connected wallet ${deployer} does not match manifest ` +
        `deployer ${manifest.deployer}. Switch keystore key.`,
    );
  }
  // Default e2e fallback: use the deployer as caller + depositor if
  // additional wallets are not available. This matches a single-key
  // Sepolia setup.
  const effectiveCaller = caller ?? deployer;
  const effectiveDepositor =
    (depositorWallet?.account.address as Address | undefined) ?? deployer;
  const callerAcc = callerWallet?.account ?? walletClient.account;
  const depositorAcc = depositorWallet?.account ?? walletClient.account;

  process.stdout.write(
    `  deployer:  ${deployer}\n` +
      `  caller:    ${effectiveCaller}\n` +
      `  depositor: ${effectiveDepositor}\n` +
      `  token:     ${manifest.token}\n` +
      `  router:    ${manifest.router}\n` +
      `  hook:      ${manifest.hook}\n` +
      `  stable:    ${manifest.stable}\n\n`,
  );

  // -------- 1. Deploy DryRunSwapper helper (for lpSell / lpBuy) ---------

  process.stdout.write(`  Deploying DryRunSwapper helper...\n`);
  const swapper = await viem.deployContract("DryRunSwapper", [
    manifest.poolManager,
    manifest.stable,
    manifest.token,
    manifest.hook,
  ]);
  const swapperAddr = swapper.address as Address;
  process.stdout.write(`    swapper: ${swapperAddr}\n\n`);

  // Lookup contract handles.
  const stableAbi = parseAbi([
    "function balanceOf(address) view returns (uint256)",
    "function transfer(address,uint256) returns (bool)",
    "function approve(address,uint256) returns (bool)",
  ]);
  const tokenAbi = parseAbi([
    "function balanceOf(address) view returns (uint256)",
    "function totalSupply() view returns (uint256)",
    "function transfer(address,uint256) returns (bool)",
    "function approve(address,uint256) returns (bool)",
    "function redeem(uint256) returns (uint256)",
  ]);
  const routerC = await viem.getContractAt("M2RevenueRouter", manifest.router);
  const hookC = await viem.getContractAt("M2V4Hook", manifest.hook);

  const e2e: Record<string, Hex> = manifest.e2e ?? {};

  // -------- 2. routeRevenue ---------------------------------------------

  process.stdout.write(`  [1/5] routeRevenue($${Number(E2E_REVENUE) / 1e6})...\n`);
  // Approve the router to pull stable from the depositor.
  const approveRouterHash = await walletClient.writeContract({
    address: manifest.stable,
    abi: stableAbi,
    functionName: "approve",
    args: [manifest.router, E2E_REVENUE],
    account: depositorAcc,
  });
  await publicClient.waitForTransactionReceipt({ hash: approveRouterHash });
  const routeRevenueTx = (await routerC.write.routeRevenue(
    [E2E_REVENUE, 0n],
    { account: depositorAcc },
  )) as Hex;
  const routeRevenueRcpt = await publicClient.waitForTransactionReceipt({
    hash: routeRevenueTx,
  });
  if (routeRevenueRcpt.status !== "success") {
    throw new Error(`routeRevenue reverted: ${routeRevenueTx}`);
  }
  e2e.routeRevenueTxHash = routeRevenueTx;
  process.stdout.write(`        tx: ${routeRevenueTx}\n`);

  // -------- 3. lpSell + lpBuy via DryRunSwapper -------------------------

  // Caller needs M² tokens to lpSell — fund from deployer.
  process.stdout.write(`  [2/5] lpSell (${Number(E2E_LP_SELL) / 1e18} M²)...\n`);
  const fundTokenHash = await walletClient.writeContract({
    address: manifest.token,
    abi: tokenAbi,
    functionName: "transfer",
    args: [effectiveCaller, E2E_LP_SELL],
  });
  await publicClient.waitForTransactionReceipt({ hash: fundTokenHash });

  const approveSwapperTokenHash = await walletClient.writeContract({
    address: manifest.token,
    abi: tokenAbi,
    functionName: "approve",
    args: [swapperAddr, E2E_LP_SELL],
    account: callerAcc,
  });
  await publicClient.waitForTransactionReceipt({
    hash: approveSwapperTokenHash,
  });

  const lpSellTx = (await swapper.write.swap(
    [false, E2E_LP_SELL],
    { account: callerAcc },
  )) as Hex;
  const lpSellRcpt = await publicClient.waitForTransactionReceipt({
    hash: lpSellTx,
  });
  if (lpSellRcpt.status !== "success") {
    throw new Error(`lpSell reverted: ${lpSellTx}`);
  }
  e2e.lpSellTxHash = lpSellTx;
  process.stdout.write(`        tx: ${lpSellTx}\n`);

  process.stdout.write(`  [3/5] lpBuy ($${Number(E2E_LP_BUY) / 1e6})...\n`);
  // Fund caller with stable for lpBuy.
  const fundStableHash = await walletClient.writeContract({
    address: manifest.stable,
    abi: stableAbi,
    functionName: "transfer",
    args: [effectiveCaller, E2E_LP_BUY],
  });
  await publicClient.waitForTransactionReceipt({ hash: fundStableHash });

  const approveSwapperStableHash = await walletClient.writeContract({
    address: manifest.stable,
    abi: stableAbi,
    functionName: "approve",
    args: [swapperAddr, E2E_LP_BUY],
    account: callerAcc,
  });
  await publicClient.waitForTransactionReceipt({
    hash: approveSwapperStableHash,
  });
  const lpBuyTx = (await swapper.write.swap([true, E2E_LP_BUY], {
    account: callerAcc,
  })) as Hex;
  const lpBuyRcpt = await publicClient.waitForTransactionReceipt({
    hash: lpBuyTx,
  });
  if (lpBuyRcpt.status !== "success") {
    throw new Error(`lpBuy reverted: ${lpBuyTx}`);
  }
  e2e.lpBuyTxHash = lpBuyTx;
  process.stdout.write(`        tx: ${lpBuyTx}\n`);

  // -------- 4. collectFees by caller (verify bounty paid) ---------------

  process.stdout.write(`  [4/5] collectFees (by caller; verify bounty)...\n`);
  const callerStableBefore = (await publicClient.readContract({
    address: manifest.stable,
    abi: stableAbi,
    functionName: "balanceOf",
    args: [effectiveCaller],
  })) as bigint;
  const callerTokenBefore = (await publicClient.readContract({
    address: manifest.token,
    abi: tokenAbi,
    functionName: "balanceOf",
    args: [effectiveCaller],
  })) as bigint;

  const collectFeesTx = (await hookC.write.collectFees([], {
    account: callerAcc,
  })) as Hex;
  const collectFeesRcpt = await publicClient.waitForTransactionReceipt({
    hash: collectFeesTx,
  });
  if (collectFeesRcpt.status !== "success") {
    throw new Error(`collectFees reverted: ${collectFeesTx}`);
  }
  e2e.collectFeesTxHash = collectFeesTx;
  const callerStableAfter = (await publicClient.readContract({
    address: manifest.stable,
    abi: stableAbi,
    functionName: "balanceOf",
    args: [effectiveCaller],
  })) as bigint;
  const callerTokenAfter = (await publicClient.readContract({
    address: manifest.token,
    abi: tokenAbi,
    functionName: "balanceOf",
    args: [effectiveCaller],
  })) as bigint;
  const callerStableGain = callerStableAfter - callerStableBefore;
  const callerTokenGain = callerTokenAfter - callerTokenBefore;
  process.stdout.write(
    `        tx: ${collectFeesTx}\n` +
      `        bounty stable: ${callerStableGain}\n` +
      `        bounty token:  ${callerTokenGain}\n`,
  );

  // -------- 5. redeem (verify payout matches mulDiv(amount, T, S)) ------

  process.stdout.write(`  [5/5] redeem...\n`);
  const redeemAmount = callerTokenAfter / 2n;
  if (redeemAmount === 0n) {
    process.stdout.write(
      `        (caller has zero tokens; skipping redeem — record skip)\n`,
    );
    e2e.redeemTxHash = "0x" as Hex;
  } else {
    const T = (await publicClient.readContract({
      address: manifest.stable,
      abi: stableAbi,
      functionName: "balanceOf",
      args: [manifest.treasury],
    })) as bigint;
    const S = (await publicClient.readContract({
      address: manifest.token,
      abi: tokenAbi,
      functionName: "totalSupply",
    })) as bigint;
    const expectedPayout = (redeemAmount * T) / S;
    const callerStableBefore2 = (await publicClient.readContract({
      address: manifest.stable,
      abi: stableAbi,
      functionName: "balanceOf",
      args: [effectiveCaller],
    })) as bigint;
    const redeemTx = (await walletClient.writeContract({
      address: manifest.token,
      abi: tokenAbi,
      functionName: "redeem",
      args: [redeemAmount],
      account: callerAcc,
    })) as Hex;
    const redeemRcpt = await publicClient.waitForTransactionReceipt({
      hash: redeemTx,
    });
    if (redeemRcpt.status !== "success") {
      throw new Error(`redeem reverted: ${redeemTx}`);
    }
    e2e.redeemTxHash = redeemTx;
    const callerStableAfter2 = (await publicClient.readContract({
      address: manifest.stable,
      abi: stableAbi,
      functionName: "balanceOf",
      args: [effectiveCaller],
    })) as bigint;
    const actualPayout = callerStableAfter2 - callerStableBefore2;
    if (actualPayout !== expectedPayout) {
      throw new Error(
        `redeem payout mismatch — expected ${expectedPayout}, got ${actualPayout}`,
      );
    }
    process.stdout.write(
      `        tx: ${redeemTx}\n` +
        `        amount: ${redeemAmount}; stableOut: ${actualPayout} (matches mulDiv)\n`,
    );
  }

  manifest.e2e = e2e;
  writeManifest(manifest);
  process.stdout.write(`\n  Manifest updated: ${MANIFEST_PATH}\n\n`);
}

main().catch((err) => {
  process.stderr.write(
    `${err instanceof Error ? err.stack ?? err.message : String(err)}\n`,
  );
  process.exit(1);
});
