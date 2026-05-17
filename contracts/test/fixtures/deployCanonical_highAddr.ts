// SPDX-License-Identifier: MIT
//
// Paired-address-sort fixture: tokenAddr > stableAddr (FINAL_REPORT H4).
// ----------------------------------------------------------------------
//
// The "high-addr" companion to `deployCanonical_lowAddr.ts`. Forces
// `address(token) > address(stable)`. Under this ordering:
//   - currency0 == stable
//   - currency1 == token
//   - zeroForOne == true  → input is stable (buy fee, 0.10%)
//   - zeroForOne == false → input is token  (sell fee, 3.00%)
//
// Implementation: identical structure to the low-addr variant but
// inverts the predicate when mining the M2Token CREATE address.
// Because the low-addr variant fixed the stable at a "high" address
// (≥ 2^156), the high-addr variant uses a "low" stable address (< 2^156)
// and mines token salts until the token address exceeds it.

import { type Address, type Hex, encodeAbiParameters, getCreate2Address, keccak256, concat, parseAbi } from "viem";
import type { PublicClient } from "viem";
import { network } from "hardhat";

import {
  S0,
  T0_6DEC,
  DYNAMIC_FEE_FLAG,
  mineSalt,
  isHookBeforeSwapAddress,
  type CanonicalDeployment,
} from "./deployCanonical.ts";

export async function deployCanonical_highAddr(): Promise<CanonicalDeployment> {
  const conn = await network.connect();
  const viem = (conn as any).viem;

  try {
    await viem.artifacts.readArtifact("M2V4Hook");
  } catch {
    throw new Error("M2V4Hook artifact not found — Agent A must merge the hook first");
  }
  try {
    await viem.artifacts.readArtifact("Create2Deployer");
  } catch {
    throw new Error(
      "Create2Deployer artifact not found — Agent A must merge the helper",
    );
  }

  const [deployerWallet] = await viem.getWalletClients();
  const publicClient: PublicClient = await viem.getPublicClient();
  const deployer: Address = deployerWallet.account.address;

  // 1. PoolManager.
  const pm = await viem.deployContract("PoolManager", [deployer]);
  const poolManager: Address = pm.address;

  // 2. Create2Deployer.
  const create2 = await viem.deployContract("Create2Deployer", []);
  const create2Addr: Address = create2.address;

  // 3. Mine a MockStable salt that produces a LOW address (< 2^156).
  //    This leaves room for the M2Token's CREATE-derived address to be
  //    high enough that `tokenAddr > stableAddr`.
  const stableArtifact = await viem.artifacts.readArtifact("MockStable");
  const stableInitCode = stableArtifact.bytecode as Hex;
  const stableInitCodeHash = keccak256(stableInitCode);
  const STABLE_LOW_THRESHOLD = 1n << 156n;
  const stableMine = mineSalt(create2Addr, stableInitCodeHash, (addr) => BigInt(addr) < STABLE_LOW_THRESHOLD);
  const stable: Address = stableMine.address;
  await deployViaCreate2(viem, create2Addr, stableMine.salt, stableInitCode);

  // 4. Retry-loop a fresh deployer EOA until the M2Token's predicted
  //    CREATE address exceeds the stable's. Typical convergence is in
  //    < 5 tries because uniform random addresses are equally likely
  //    above/below 2^156.
  const treasuryArtifact = await viem.artifacts.readArtifact("M2Treasury");
  const tokenArtifact = await viem.artifacts.readArtifact("M2Token");
  const hookArtifact = await viem.artifacts.readArtifact("M2V4Hook");

  const MAX_RETRIES = 100;
  let result: CanonicalDeployment | null = null;
  for (let retry = 0; retry < MAX_RETRIES; ++retry) {
    const freshAccount = viem.privateKeyToAccount(generateFreshKey(retry));
    const freshWalletClient = await viem.getWalletClient({ account: freshAccount });
    await viem.sendTransaction({ to: freshAccount.address, value: 10n * 10n ** 18n });

    const baseNonce = await publicClient.getTransactionCount({ address: freshAccount.address });
    const trAddr = computeCreateAddress(freshAccount.address, baseNonce);
    const tkAddr = computeCreateAddress(freshAccount.address, baseNonce + 1);
    if (BigInt(tkAddr) <= BigInt(stable)) continue;

    // Mine hook salt with the final addresses.
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

    // Deploy treasury (nonce baseNonce).
    const trTx = await freshWalletClient.deployContract({
      abi: treasuryArtifact.abi,
      bytecode: treasuryArtifact.bytecode,
      args: [stable, tkAddr],
    });
    const trReceipt = await publicClient.waitForTransactionReceipt({ hash: trTx });
    if (trReceipt.contractAddress?.toLowerCase() !== trAddr.toLowerCase()) {
      throw new Error("treasury address prediction broke");
    }

    // Deploy token (nonce baseNonce+1).
    const tokenTx = await freshWalletClient.deployContract({
      abi: tokenArtifact.abi,
      bytecode: tokenArtifact.bytecode,
      args: [stable, trAddr, deployer, hookAddr, deployer, S0],
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

    // Pool key: stable is currency0, token is currency1.
    const poolKey = {
      currency0: stable,
      currency1: tkAddr,
      fee: DYNAMIC_FEE_FLAG,
      tickSpacing: 60,
      hooks: hookAddr,
    };
    await (await viem.getContractAt("PoolManager", poolManager)).write.initialize([
      [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks],
      1n << 96n,
    ]);

    result = {
      poolManager,
      stable,
      token: tkAddr,
      treasury: trAddr,
      hook: hookAddr,
      router: deployer,
      poolKey,
      stableIsCurrency0: true, // stable < token, so stable is currency0
      deployer,
      depositor: deployer,
    };
    break;
  }

  if (!result) {
    throw new Error(
      `deployCanonical_highAddr: exhausted ${MAX_RETRIES} retries without satisfying tokenAddr > stableAddr`,
    );
  }
  if (BigInt(result.token) <= BigInt(result.stable)) {
    throw new Error("post-deploy ordering check failed: token <= stable");
  }
  return result;
}

// -----------------------------------------------------------------------------
// Local helpers (duplicated for self-containment; see deployCanonical.ts)
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
  const buf = new Uint8Array(32);
  let s = seed + 1;
  for (let i = 31; i >= 0; --i) {
    buf[i] = s & 0xff;
    s = Math.floor(s / 256);
  }
  return `0x${Array.from(buf).map((b) => b.toString(16).padStart(2, "0")).join("")}` as Hex;
}
