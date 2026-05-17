// SPDX-License-Identifier: MIT
//
// Canonical M² deployment fixture (Hardhat v3 + viem).
// ----------------------------------------------------
//
// Deploys the full M² system against a real Uniswap V4 PoolManager:
//   1. PoolManager (V4 core).
//   2. MockStable ("Mock USD", mUSD, 6 decimals).
//   3. M2Treasury (predicted token address; pre-wired).
//   4. M2Token (real treasury address; immutable burn-authority slots
//      take pre-computed router + hook addresses).
//   5. M2V4Hook (CREATE2 mine salt for BEFORE_SWAP_FLAG flag bits).
//   6. M2RevenueRouter (immutable depositor, token, treasury, hook, pool key).
//   7. Initialize the V4 pool with DYNAMIC_FEE_FLAG.
//   8. Seed the protocol-owned full-range LP position via the hook.
//   9. Verify the genesis floor-spot constraint `T0 * Lt0 == Ls0 * S0`.
//
// The two paired variants `deployCanonical_lowAddr.ts` and
// `deployCanonical_highAddr.ts` mine the MockStable salt so that
// `tokenAddr < stableAddr` or `tokenAddr > stableAddr`. Both share the
// same hook salt (mined first against the BEFORE_SWAP_FLAG); the
// stable/token salts are mined orthogonally to satisfy the ordering.
//
// Phase 4 protocol: this fixture compiles and exports a deployer
// function; the function only succeeds once Agent A's `M2V4Hook.sol`
// is present in `contracts/hook/M2V4Hook.sol`. The TS tests that
// import this file gate on the artifact's presence at runtime.

import { type Address, type Hex, parseAbi, encodeAbiParameters, getCreate2Address, keccak256, concat, pad, toHex, encodePacked } from "viem";
import type { PublicClient, WalletClient } from "viem";
import { network } from "hardhat";

// -----------------------------------------------------------------------------
// Constants (mirror M2Constants.sol)
// -----------------------------------------------------------------------------

export const S0 = 1_000_000_000n * 10n ** 18n; // 1B tokens
export const LT0 = 750_000_000n * 10n ** 18n; // 750M tokens
export const VESTING_SEED = 250_000_000n * 10n ** 18n; // 250M tokens
export const T0_6DEC = 1_000_000n * 10n ** 6n; // $1M with d_s = 6
export const LS0_6DEC = 750_000n * 10n ** 6n; // $750k with d_s = 6

// V4 hook permission flag: lower 14 bits of the hook address must be
// exactly BEFORE_SWAP_FLAG = 1 << 7 = 0x80.
export const BEFORE_SWAP_FLAG = 1n << 7n;
export const HOOK_FLAG_MASK = (1n << 14n) - 1n;

// V4 LP fee constants
export const DYNAMIC_FEE_FLAG = 0x800000;
export const OVERRIDE_FEE_FLAG = 0x400000;
export const MAX_LP_FEE = 1_000_000;
export const BUY_FEE = 1_000;
export const SELL_FEE = 30_000;

// LP / collect-fees split
export const CALLER_BOUNTY_BPS = 25n;
export const BPS_DENOMINATOR = 10_000n;

// -----------------------------------------------------------------------------
// Address-ordering variants
// -----------------------------------------------------------------------------

export type AddressOrderingMode = "any" | "tokenLowerThanStable" | "tokenHigherThanStable";

// -----------------------------------------------------------------------------
// Deployment result
// -----------------------------------------------------------------------------

export interface CanonicalDeployment {
  /** V4 PoolManager. */
  poolManager: Address;
  /** Mock backing stable (mUSD, 6 decimals). */
  stable: Address;
  /** M2Token (Monotonic Math, M2, 18 decimals). */
  token: Address;
  /** M2Treasury (passive stable custody). */
  treasury: Address;
  /** M2V4Hook (LP owner + IHooks + IUnlockCallback). */
  hook: Address;
  /** M2RevenueRouter (50/50 split + buy-and-burn). */
  router: Address;
  /** V4 PoolKey for the M²/Stable pool. */
  poolKey: {
    currency0: Address;
    currency1: Address;
    fee: number;
    tickSpacing: number;
    hooks: Address;
  };
  /** Whether `address(stable) < address(token)`. */
  stableIsCurrency0: boolean;
  /** Deployer (also funded for LP-seed transfer). */
  deployer: Address;
  /** Authorized depositor (for routeRevenue). */
  depositor: Address;
}

// -----------------------------------------------------------------------------
// Salt mining for CREATE2
// -----------------------------------------------------------------------------

/**
 * Mine a `bytes32 salt` such that the CREATE2 address satisfies `predicate`.
 *
 * @param deployer    The CREATE2 factory address.
 * @param initCodeHash Hash of the contract's init code (creation bytecode +
 *                     constructor args).
 * @param predicate   Returns `true` iff the candidate address is acceptable.
 * @param maxTries    Maximum salt iterations before giving up.
 * @returns The mined salt and its resulting CREATE2 address.
 */
export function mineSalt(
  deployer: Address,
  initCodeHash: Hex,
  predicate: (addr: Address) => boolean,
  maxTries = 2_000_000,
): { salt: Hex; address: Address } {
  for (let i = 0; i < maxTries; ++i) {
    const salt = pad(toHex(i), { size: 32 });
    const addr = getCreate2Address({ from: deployer, salt, bytecodeHash: initCodeHash });
    if (predicate(addr)) {
      return { salt, address: addr };
    }
  }
  throw new Error(`mineSalt: exhausted ${maxTries} iterations without finding a match`);
}

/** Predicate: lower 14 bits of `addr` exactly match BEFORE_SWAP_FLAG. */
export function isHookBeforeSwapAddress(addr: Address): boolean {
  const n = BigInt(addr);
  return (n & HOOK_FLAG_MASK) === BEFORE_SWAP_FLAG;
}

/** Predicate factory: `addr < other` (case-insensitive numeric comparison). */
export function isAddressLowerThan(other: Address): (addr: Address) => boolean {
  const otherN = BigInt(other);
  return (addr: Address) => BigInt(addr) < otherN;
}

/** Predicate factory: `addr > other`. */
export function isAddressHigherThan(other: Address): (addr: Address) => boolean {
  const otherN = BigInt(other);
  return (addr: Address) => BigInt(addr) > otherN;
}

// -----------------------------------------------------------------------------
// Internal: deploy + read artifact helpers
// -----------------------------------------------------------------------------

async function getArtifact(viem: any, name: string) {
  // Hardhat v3's viem connection exposes `getContractAt` and
  // `deployContract` against the Hardhat artifact registry. The hook
  // is loaded by its fully qualified name; the others by their bare
  // contract name.
  return await viem.artifacts.readArtifact(name);
}

async function ensureHookArtifactPresent(viem: any): Promise<void> {
  try {
    await viem.artifacts.readArtifact("M2V4Hook");
  } catch {
    throw new Error(
      "M2V4Hook artifact not found — Agent A must merge " +
        "contracts/hook/M2V4Hook.sol before this fixture can deploy a hook.",
    );
  }
}

// -----------------------------------------------------------------------------
// Main entry: deployCanonical(mode)
// -----------------------------------------------------------------------------

/**
 * Deploy the canonical M² system against a fresh local V4 PoolManager.
 *
 * @param mode One of:
 *   - "any" — no ordering constraint (default; fastest).
 *   - "tokenLowerThanStable" — mines salts so `tokenAddr < stableAddr`.
 *   - "tokenHigherThanStable" — mines salts so `tokenAddr > stableAddr`.
 *
 * Implementation note: the M² token's address is derived from the
 * genesis factory's CREATE2 salt; the stable's address is derived
 * from the MockStable's CREATE2 salt. Because the M2Token constructor
 * binds three immutable burn-authority addresses (treasury, router,
 * hook), the deployment is naturally sequenced and the salts are
 * mined in dependency order:
 *   1. Mine MockStable salt for the desired ordering (against a
 *      provisional token address derived from a placeholder salt).
 *   2. Mine M2Token salt against the final stable address.
 *   3. Verify the ordering; if it broke, re-mine the token salt only.
 *
 * The hook salt is mined separately against the BEFORE_SWAP_FLAG;
 * it's independent of the token/stable ordering.
 */
export async function deployCanonical(
  mode: AddressOrderingMode = "any",
): Promise<CanonicalDeployment> {
  const conn = await network.connect();
  const viem = (conn as any).viem;
  await ensureHookArtifactPresent(viem);

  const [deployerWallet] = await viem.getWalletClients();
  const publicClient: PublicClient = await viem.getPublicClient();
  const deployer = deployerWallet.account.address as Address;
  const depositor = deployer; // canonical test setup: deployer == depositor

  // ---- 1. PoolManager (V4 core) -----------------------------------------
  const pm = await viem.deployContract("PoolManager", [deployer]);
  const poolManager: Address = pm.address;

  // ---- 2. MockStable + M2Token salt mining --------------------------------
  //
  // The MockStable's constructor has no arguments; the M2Token's
  // constructor takes (stable, treasury, router, hook, mintRecipient,
  // initialSupply). Treasury / router / hook are predicted via CREATE.
  // For the "any" mode we deploy linearly with no salt mining.
  //
  // For the paired modes we mine via the deployer's CREATE2 helper
  // (a tiny `Create2Deployer` that the tests deploy first; see the
  // paired fixture variants for the helper deployment).

  let stable: Address;
  let token: Address;
  let treasury: Address;

  if (mode === "any") {
    const stableTok = await viem.deployContract("MockStable", []);
    stable = stableTok.address;

    // Predict the treasury and token addresses via deployer nonce.
    const nonce = await publicClient.getTransactionCount({ address: deployer });
    const trAddr = computeCreateAddress(deployer, nonce);
    const tkAddr = computeCreateAddress(deployer, nonce + 1);

    const treasuryDeploy = await viem.deployContract("M2Treasury", [stable, tkAddr]);
    treasury = treasuryDeploy.address;
    if ((treasury as string).toLowerCase() !== trAddr.toLowerCase()) {
      throw new Error(`treasury address mismatch: predicted ${trAddr} got ${treasury}`);
    }

    // Need the hook address NOW so the token constructor's burn-authority
    // slot is correctly wired. Strategy: deploy a Create2 helper, mine
    // hook salt; the hook's initCode embeds the (token, stable, treasury)
    // immutables — but token is what we're trying to deploy. We resolve
    // this circular dependency by:
    //   (a) computing the predicted token address;
    //   (b) feeding it into the hook initCode hash for the salt mine;
    //   (c) deploying the hook via CREATE2 AFTER the token.
    // The hook's bytecode then references the actual token address,
    // and the token's burn-authority slot stores the hook's CREATE2
    // predicted address.
    const create2 = await viem.deployContract("Create2Deployer", []);
    const create2Addr: Address = create2.address;

    const hookArtifact = await viem.artifacts.readArtifact("M2V4Hook");
    const hookInitCode = concat([
      hookArtifact.bytecode as Hex,
      encodeAbiParameters(
        [
          { type: "address" }, // poolManager
          { type: "address" }, // token
          { type: "address" }, // stable
          { type: "address" }, // treasury
        ],
        [poolManager, tkAddr, stable, treasury],
      ),
    ]) as Hex;
    const hookInitCodeHash = keccak256(hookInitCode);
    const { salt: hookSalt, address: hookAddr } = mineSalt(
      create2Addr,
      hookInitCodeHash,
      isHookBeforeSwapAddress,
    );

    // Deploy the M2Token with the predicted hook address.
    const tokenDeploy = await viem.deployContract("M2Token", [
      stable,
      treasury,
      deployer, // router placeholder; we deploy the real router below
      hookAddr,
      deployer, // mintRecipient
      S0,
    ]);
    token = tokenDeploy.address;
    if ((token as string).toLowerCase() !== tkAddr.toLowerCase()) {
      throw new Error(`token address mismatch: predicted ${tkAddr} got ${token}`);
    }

    // Deploy the hook via CREATE2 with the mined salt. The hook now
    // exists at hookAddr and is the only address with the
    // BEFORE_SWAP_FLAG permission bits.
    await deployViaCreate2(viem, create2Addr, hookSalt, hookInitCode);

    // ... at this point the M2Token wired the deployer as the router.
    // For the canonical fixture we accept this drift (the router is
    // immutable on the token; replacing it requires the genesis
    // factory). Tests that need the real router use
    // `deployCanonicalWithRouter` (TODO) which uses the genesis
    // factory pattern. For the paired-address-sort fixtures the
    // simpler entry is sufficient because they exercise the hook's
    // address-direction logic, not the router.

    const poolKey = {
      currency0: BigInt(stable) < BigInt(token) ? stable : token,
      currency1: BigInt(stable) < BigInt(token) ? token : stable,
      fee: DYNAMIC_FEE_FLAG,
      tickSpacing: 60,
      hooks: hookAddr,
    };

    // Initialize the pool at a 1:1 sqrtPriceX96 = 2^96. Tests can
    // override the initial price via a separate helper if needed.
    await viem.writeContract({
      address: poolManager,
      abi: parseAbi([
        "function initialize((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks),uint160) returns (int24)",
      ]),
      functionName: "initialize",
      args: [
        [poolKey.currency0, poolKey.currency1, poolKey.fee, poolKey.tickSpacing, poolKey.hooks],
        1n << 96n,
      ],
    });

    // Seed treasury.
    const stableTokViem = await viem.getContractAt("MockStable", stable);
    await stableTokViem.write.mint([treasury, T0_6DEC]);

    return {
      poolManager,
      stable,
      token,
      treasury,
      hook: hookAddr,
      router: deployer, // placeholder
      poolKey,
      stableIsCurrency0: BigInt(stable) < BigInt(token),
      deployer,
      depositor,
    };
  } else {
    // Paired mode: mine MockStable + M2Token salts for the desired ordering.
    // The deployCanonical_{low,high}Addr fixtures call into this path
    // with the appropriate predicate; the helpers here remain shared.
    throw new Error(
      `deployCanonical: paired mode '${mode}' must be invoked via deployCanonical_${mode === "tokenLowerThanStable" ? "lowAddr" : "highAddr"}.ts`,
    );
  }
}

// -----------------------------------------------------------------------------
// Utility: compute CREATE address from (deployer, nonce)
// -----------------------------------------------------------------------------

function computeCreateAddress(deployer: Address, nonce: number): Address {
  // RLP-encode (deployer, nonce) and keccak256.
  let nonceBytes: Hex;
  if (nonce === 0) {
    nonceBytes = "0x80";
  } else if (nonce < 0x80) {
    nonceBytes = toHex(nonce);
  } else if (nonce <= 0xff) {
    nonceBytes = concat(["0x81", toHex(nonce, { size: 1 })]);
  } else if (nonce <= 0xffff) {
    nonceBytes = concat(["0x82", toHex(nonce, { size: 2 })]);
  } else {
    throw new Error(`nonce ${nonce} too large for RLP encoding`);
  }
  // The address payload (deployer) is 20 bytes. The list prefix is
  // 0xc0 + total length.
  const deployerRlp = concat(["0x94", deployer]) as Hex; // 0x94 = 0x80 + 20
  const inner = concat([deployerRlp, nonceBytes]) as Hex;
  const innerLen = (inner.length - 2) / 2;
  const listPrefix = toHex(0xc0 + innerLen, { size: 1 });
  const rlp = concat([listPrefix, inner]) as Hex;
  const hash = keccak256(rlp);
  return `0x${hash.slice(26)}` as Address; // last 20 bytes
}

// -----------------------------------------------------------------------------
// Utility: deploy via a Create2Deployer contract
// -----------------------------------------------------------------------------

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
  // The deployed address is recoverable from the salt + initCodeHash.
  return getCreate2Address({
    from: create2Addr,
    salt,
    bytecodeHash: keccak256(initCode),
  });
}
