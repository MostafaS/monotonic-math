// SPDX-License-Identifier: MIT
//
// Paired-address-sort fixture: tokenAddr < stableAddr (FINAL_REPORT H4).
// ---------------------------------------------------------------------
//
// V4 sorts pool currencies by raw address (currency0 < currency1). The
// hook's fee-direction logic must work under BOTH orderings:
//
//   - "low-addr"  variant: `address(token) < address(stable)`
//     → currency0 == token, currency1 == stable
//     → zeroForOne == true   means input is token   (sell fee, 3.00%)
//     → zeroForOne == false  means input is stable  (buy  fee, 0.10%)
//
//   - "high-addr" variant: `address(token) > address(stable)`
//     → currency0 == stable, currency1 == token
//     → zeroForOne == true   means input is stable  (buy  fee, 0.10%)
//     → zeroForOne == false  means input is token   (sell fee, 3.00%)
//
// The hook MUST derive direction from the input currency address
// (`inputCurrency = zeroForOne ? currency0 : currency1`), not from
// `zeroForOne` alone. The paired CI fixtures run the full integration
// suite under both orderings to catch any regression that hardcodes
// the assumption.
//
// Implementation: this fixture deploys a `Create2Deployer` helper,
// then mines a MockStable CREATE2 salt that produces a stable address
// strictly greater than the (separately predicted) M2Token address.
// The hook salt is mined independently against the BEFORE_SWAP_FLAG.

import { type Address, type Hex, encodeAbiParameters, getCreate2Address, keccak256, concat, parseAbi } from "viem";
import type { PublicClient } from "viem";
import { network } from "hardhat";

import {
  S0,
  LT0,
  T0_6DEC,
  LS0_6DEC,
  DYNAMIC_FEE_FLAG,
  mineSalt,
  isHookBeforeSwapAddress,
  isAddressHigherThan,
  type CanonicalDeployment,
} from "./deployCanonical.ts";

export async function deployCanonical_lowAddr(): Promise<CanonicalDeployment> {
  const conn = await network.connect();
  const viem = (conn as any).viem;

  // Gate on Agent A's artifact.
  try {
    await viem.artifacts.readArtifact("M2V4Hook");
  } catch {
    throw new Error("M2V4Hook artifact not found — Agent A must merge the hook first");
  }
  try {
    await viem.artifacts.readArtifact("Create2Deployer");
  } catch {
    throw new Error(
      "Create2Deployer artifact not found — Agent A must merge the helper " +
        "(contracts/genesis/Create2Deployer.sol) before paired fixtures can deploy.",
    );
  }

  const [deployerWallet] = await viem.getWalletClients();
  const publicClient: PublicClient = await viem.getPublicClient();
  const deployer: Address = deployerWallet.account.address;

  // 1. PoolManager.
  const pm = await viem.deployContract("PoolManager", [deployer]);
  const poolManager: Address = pm.address;

  // 2. Create2Deployer helper.
  const create2 = await viem.deployContract("Create2Deployer", []);
  const create2Addr: Address = create2.address;

  // 3. Mine MockStable salt that produces an arbitrary address (any
  //    valid address — we don't yet know the token address, so we
  //    deploy the stable first, then mine the token salt against it).
  const stableArtifact = await viem.artifacts.readArtifact("MockStable");
  const stableInitCode = stableArtifact.bytecode as Hex; // no constructor args
  const stableInitCodeHash = keccak256(stableInitCode);

  // For the low-addr variant we want a stable address that allows
  // *some* token address with `tokenAddr < stableAddr` to be mineable.
  // Choosing a high-bit stable address simplifies the token salt mine.
  const STABLE_HIGH_THRESHOLD = (1n << 156n); // any address > 2^156
  const stableMine = mineSalt(create2Addr, stableInitCodeHash, (addr) => BigInt(addr) >= STABLE_HIGH_THRESHOLD);
  const stable: Address = stableMine.address;
  await deployViaCreate2(viem, create2Addr, stableMine.salt, stableInitCode);

  // 4. Predict treasury, token addresses from deployer nonce.
  // We deploy treasury via direct CREATE (the M2Token constructor takes
  // the treasury address as input, and the treasury constructor takes
  // the predicted token address — same circular wiring as the unit
  // test). Predict via CREATE2 from the create2 helper.
  // Treasury address: derive from a salt mine that picks any value
  // (treasury address does not matter for the ordering).
  const treasuryArtifact = await viem.artifacts.readArtifact("M2Treasury");
  // We need to predict the token address before deploying the
  // treasury (because the treasury's constructor stores the token
  // address as an immutable). The token's address depends on its own
  // salt — which depends on the immutable burn-authority slot for the
  // treasury... we break the circular by:
  //   (a) mining a token salt that produces an address < stable's; the
  //       token's constructor args include treasury (unknown) and hook
  //       (unknown);
  //   (b) treating the unknown treasury + hook addresses as inputs to
  //       the token's initCodeHash; we resolve them by alternating
  //       fixed-point iteration until all three salts are mutually
  //       consistent.
  //
  // For deterministic test setup we use a simpler approach: deploy
  // the treasury at a fixed CREATE address (deployer nonce N), then
  // mine the token salt against that treasury address; finally mine
  // the hook salt against the token address. This sequencing means
  // the M2Token's constructor receives the actual treasury address;
  // the M2Treasury's constructor receives the *predicted* token
  // address (via mineSalt's deterministic salt → predicted address
  // mapping).

  // Token salt mining. Args: (stable, treasury, router, hook,
  // mintRecipient, initialSupply). We mine against the predicate
  // `tokenAddr < stableAddr`. The treasury address is predicted from
  // the deployer's nonce (next CREATE); the hook + router are
  // resolved last.
  // Initialize router and hook addresses as placeholders — the salt
  // mine yields the same token address regardless of the constructor
  // args, AS LONG AS the constructor args are bit-for-bit the same
  // at the actual deploy. So we mine with placeholders, deploy
  // treasury, then re-mine the token salt with the actual treasury
  // address.
  //
  // SIMPLIFICATION FOR THIS FIXTURE: we use the deployer's plain CREATE
  // (not CREATE2) for the M2Token; the address is determined by the
  // deployer's nonce. We deploy the contracts in this order:
  //   1. PoolManager (deployer CREATE nonce n0).
  //   2. Create2Deployer (n0+1).
  //   3. MockStable (CREATE2 mined for high address). [creates from create2 addr]
  //   4. M2Treasury (n0+2) — predicted via deployer nonce.
  //   5. M2Token (n0+3) — predicted via deployer nonce.
  //   6. Mine hook salt against the token address.
  //   7. Hook deployed via CREATE2.
  //   8. M2RevenueRouter (n0+4) — wired with the hook.
  //
  // Under this layout we can check the ordering AFTER step 5 and
  // re-roll a fresh fixture if the ordering broke (i.e. the test
  // contract uses a different deployer nonce).
  //
  // The simpler retry approach: deploy a few fresh deployer EOAs (via
  // viem.getWalletClients() with multiple accounts) and select the one
  // whose nonce-derived token address satisfies the ordering.

  // For practical use we attempt up to 100 token CREATE iterations
  // (by deploying-and-discarding the treasury/token chain) until the
  // ordering is satisfied.
  const MAX_RETRIES = 100;
  let bestDeployment: CanonicalDeployment | null = null;
  for (let retry = 0; retry < MAX_RETRIES; ++retry) {
    // Use a fresh wallet for each retry so the deployer nonce is
    // reset to zero relative to a clean slate. The simplest path is
    // to fund a fresh test EOA and use it.
    const freshAccount = viem.privateKeyToAccount(generateFreshKey(retry));
    const freshWalletClient = await viem.getWalletClient({ account: freshAccount });
    // Fund the fresh EOA with some ETH for gas.
    await viem.sendTransaction({
      to: freshAccount.address,
      value: 10n * 10n ** 18n,
    });
    const baseNonce = await publicClient.getTransactionCount({
      address: freshAccount.address,
    });
    const trAddr = computeCreateAddress(freshAccount.address, baseNonce);
    const tkAddr = computeCreateAddress(freshAccount.address, baseNonce + 1);
    if (BigInt(tkAddr) >= BigInt(stable)) {
      continue; // ordering not satisfied; try a fresh deployer
    }

    // Mine hook salt against this token address.
    const hookArtifact = await viem.artifacts.readArtifact("M2V4Hook");
    // For the salt mine we need the final treasury and router
    // addresses. Treasury is trAddr; router we set as freshAccount
    // (placeholder; the router is deployed later, but the hook only
    // stores the addresses for view-surface purposes — the hook's
    // constructor signature is `(IPoolManager, address token,
    // address stable, address treasury)` per the IM2Hook interface).
    const hookInitCode = concat([
      hookArtifact.bytecode as Hex,
      encodeAbiParameters(
        [
          { type: "address" }, // poolManager
          { type: "address" }, // token
          { type: "address" }, // stable
          { type: "address" }, // treasury
        ],
        [poolManager, tkAddr, stable, trAddr],
      ),
    ]) as Hex;
    const hookInitCodeHash = keccak256(hookInitCode);
    const hookMine = mineSalt(create2Addr, hookInitCodeHash, isHookBeforeSwapAddress);
    const hookAddr: Address = hookMine.address;

    // Deploy treasury (nonce baseNonce) via the fresh wallet.
    const trTx = await freshWalletClient.deployContract({
      abi: treasuryArtifact.abi,
      bytecode: treasuryArtifact.bytecode,
      args: [stable, tkAddr],
    });
    const trReceipt = await publicClient.waitForTransactionReceipt({ hash: trTx });
    if (trReceipt.contractAddress?.toLowerCase() !== trAddr.toLowerCase()) {
      throw new Error("treasury address prediction broke");
    }

    // Deploy token (nonce baseNonce+1) via the fresh wallet.
    const tokenArtifact = await viem.artifacts.readArtifact("M2Token");
    const tokenTx = await freshWalletClient.deployContract({
      abi: tokenArtifact.abi,
      bytecode: tokenArtifact.bytecode,
      args: [
        stable,
        trAddr,
        deployer, // router placeholder
        hookAddr,
        deployer, // mintRecipient
        S0,
      ],
    });
    const tokenReceipt = await publicClient.waitForTransactionReceipt({ hash: tokenTx });
    if (tokenReceipt.contractAddress?.toLowerCase() !== tkAddr.toLowerCase()) {
      throw new Error("token address prediction broke");
    }

    // Deploy hook via CREATE2.
    await deployViaCreate2(viem, create2Addr, hookMine.salt, hookInitCode);

    // Treasury seed.
    const stableContract = await viem.getContractAt("MockStable", stable);
    await stableContract.write.mint([trAddr, T0_6DEC]);

    // Initialize pool (currency0 = token, currency1 = stable for low-addr).
    const poolKey = {
      currency0: tkAddr,
      currency1: stable,
      fee: DYNAMIC_FEE_FLAG,
      tickSpacing: 60,
      hooks: hookAddr,
    };
    await (await viem.getContractAt("PoolManager", poolManager)).write.initialize([
      [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks],
      1n << 96n,
    ]);

    bestDeployment = {
      poolManager,
      stable,
      token: tkAddr,
      treasury: trAddr,
      hook: hookAddr,
      router: deployer, // placeholder
      poolKey,
      stableIsCurrency0: false, // token < stable, so token is currency0
      deployer,
      depositor: deployer,
    };
    break;
  }

  if (!bestDeployment) {
    throw new Error(`deployCanonical_lowAddr: exhausted ${MAX_RETRIES} retries without satisfying tokenAddr < stableAddr`);
  }
  // Sanity check the ordering: token < stable.
  if (BigInt(bestDeployment.token) >= BigInt(bestDeployment.stable)) {
    throw new Error("post-deploy ordering check failed: token >= stable");
  }
  return bestDeployment;
}

// -----------------------------------------------------------------------------
// Helpers (duplicated from deployCanonical.ts intentionally — keeps the
// paired fixtures self-contained for clarity).
// -----------------------------------------------------------------------------

function computeCreateAddress(deployer: Address, nonce: number): Address {
  let nonceBytes: Hex;
  if (nonce === 0) nonceBytes = "0x80";
  else if (nonce < 0x80) nonceBytes = `0x${nonce.toString(16).padStart(2, "0")}` as Hex;
  else if (nonce <= 0xff) nonceBytes = `0x81${nonce.toString(16).padStart(2, "0")}` as Hex;
  else if (nonce <= 0xffff) nonceBytes = `0x82${nonce.toString(16).padStart(4, "0")}` as Hex;
  else throw new Error(`nonce ${nonce} too large`);
  const deployerRlp = concat(["0x94", deployer]) as Hex;
  const inner = concat([deployerRlp, nonceBytes]) as Hex;
  const innerLen = (inner.length - 2) / 2;
  const listPrefix = `0x${(0xc0 + innerLen).toString(16).padStart(2, "0")}` as Hex;
  const rlp = concat([listPrefix, inner]) as Hex;
  const hash = keccak256(rlp);
  return `0x${hash.slice(26)}` as Address;
}

async function deployViaCreate2(
  viem: any,
  create2Addr: Address,
  salt: Hex,
  initCode: Hex,
): Promise<Address> {
  const [wallet] = await viem.getWalletClients();
  const txHash = await wallet.writeContract({
    address: create2Addr,
    abi: parseAbi(["function deploy(bytes32 salt, bytes calldata initCode) returns (address)"]),
    functionName: "deploy",
    args: [salt, initCode],
  });
  const publicClient: PublicClient = await viem.getPublicClient();
  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
  if (receipt.status !== "success") throw new Error("CREATE2 deploy failed");
  return getCreate2Address({ from: create2Addr, salt, bytecodeHash: keccak256(initCode) });
}

function generateFreshKey(seed: number): Hex {
  // Deterministic 32-byte private key from `seed` so test runs are
  // reproducible. The key has no real value — it's a local-only EOA
  // funded by the test wallet for the duration of the test.
  const buf = new Uint8Array(32);
  let s = seed + 1; // avoid all-zero key
  for (let i = 31; i >= 0; --i) {
    buf[i] = s & 0xff;
    s = Math.floor(s / 256);
  }
  return `0x${Array.from(buf).map((b) => b.toString(16).padStart(2, "0")).join("")}` as Hex;
}
