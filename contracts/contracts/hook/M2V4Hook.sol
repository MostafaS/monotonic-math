// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IM2Token} from "../interfaces/IM2Token.sol";
import {IM2Treasury} from "../interfaces/IM2Treasury.sol";
import {IM2Events} from "../libraries/M2Events.sol";
import {M2Constants} from "../libraries/M2Constants.sol";
import {M2Errors} from "../libraries/M2Errors.sol";

/// @title M2V4Hook — Merged V4 hook + LP owner + permissionless `collectFees`
/// @author M² / Monotonic Math
/// @notice Single contract that (a) implements `IHooks.beforeSwap` with the
///         asymmetric dynamic fee (buy 0.10% on stable input, sell 3.00% on
///         token input), (b) owns the V4 LP position permanently, (c)
///         implements `IUnlockCallback` for V4 flash-accounting, and (d)
///         exposes the permissionless `collectFees()` entry point. The merge
///         is mandated by paper §3.2's enumeration of exactly THREE
///         burn-authority roles (hook, router, self-redeem); a separate LP
///         manager would introduce a fourth role.
/// @dev    NO inheritance of Ownable / AccessControl / Pausable /
///         UUPSUpgradeable / BaseHook. The hook implements `IHooks` directly
///         to avoid the periphery `BaseHook` remapping conflict
///         (v4-periphery 1.0.3 ships its own bundled `lib/v4-core/`, and
///         Hardhat 3 honors each package's `remappings.txt`; importing
///         BaseHook would pull in a SECOND, type-incompatible copy of
///         every v4-core type into the compilation unit).
///
///         NO admin, NO upgrade path, NO pause, NO rescue, NO setter on
///         any immutable or pool reference. No externally callable function
///         reduces the protocol-owned LP position. The `unlockCallback`
///         rejects every caller other than the immutable V4 PoolManager.
///         Direction-detection is derived from the input currency
///         (FINAL_REPORT §H4); `zeroForOne` is NEVER hardcoded as buy or
///         sell. The only enabled hook permission is `beforeSwap`.
///
///         CREATE2 salt-mining: V4 requires the hook's address to encode
///         its permission flags in the bottom 14 bits. Only
///         `BEFORE_SWAP_FLAG` (1 << 7 = 0x0080) is set here. The
///         accompanying TypeScript script
///         `scripts/deploy/mine_hook_salt.ts` mines a salt s.t. the
///         resulting CREATE2 address satisfies
///         `addr & ALL_HOOK_MASK == BEFORE_SWAP_FLAG`. The constructor
///         calls `Hooks.validateHookPermissions(this, getHookPermissions())`
///         and reverts if the address is wrong.
contract M2V4Hook is IHooks, IM2Events, IUnlockCallback {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Immutable wiring (paper §3.1 — no setter, no upgrade)
    // -----------------------------------------------------------------

    /// @notice Uniswap V4 PoolManager. The only address allowed to invoke any
    ///         `IHooks` callback or `unlockCallback` on this contract.
    IPoolManager public immutable POOL_MANAGER;

    /// @dev The M² token. Burn target for the 99.75% token-side fee burn;
    ///      one of the three burn authorities (paper §3.2).
    IM2Token private immutable _TOKEN;

    /// @dev Backing stablecoin. Currency for the 99.75% stable-side treasury
    ///      forward and the 0.25% caller bounty.
    IERC20 private immutable _STABLE;

    /// @dev Passive custody treasury contract.
    IM2Treasury private immutable _TREASURY;

    /// @dev `true` iff `_STABLE` is `currency0` in the configured pool key
    ///      (precomputed from the V4 address sort at construction;
    ///      FINAL_REPORT §H4).
    bool private immutable _STABLE_IS_CURRENCY0;

    // -----------------------------------------------------------------
    // Pool key + LP position (written once in `initializePool`, never mutated)
    // -----------------------------------------------------------------

    /// @dev `PoolKey` cannot be `immutable` (contains struct fields and a
    ///      user-defined-value type), so we store it in storage and gate
    ///      writes to a single one-shot path. No function in this contract
    ///      writes to this field after `initializePool` returns.
    PoolKey private _poolKey;

    /// @dev `true` once `initializePool` has run; further calls revert.
    bool private _initialized;

    /// @dev Lower tick of the protocol-owned full-range position
    ///      (`minUsableTick(tickSpacing)`).
    int24 private _tickLower;

    /// @dev Upper tick of the protocol-owned full-range position
    ///      (`maxUsableTick(tickSpacing)`).
    int24 private _tickUpper;

    // -----------------------------------------------------------------
    // Unlock-callback action discriminators (private to this contract)
    // -----------------------------------------------------------------

    uint8 private constant _ACTION_INIT_LP = 1;
    uint8 private constant _ACTION_COLLECT_FEES = 2;

    // -----------------------------------------------------------------
    // Errors specific to this contract (M2Errors is shared)
    // -----------------------------------------------------------------

    /// @notice Thrown when `initializePool` is called after the pool has
    ///         already been initialized.
    error AlreadyInitialized();

    /// @notice Thrown when an LP-only helper is invoked before the pool has
    ///         been initialized.
    error NotInitialized();

    /// @notice Thrown when any `IHooks` callback other than `beforeSwap` is
    ///         invoked. The hook only opts into `beforeSwap`; V4 routes by
    ///         permission flags, but a defense-in-depth revert blocks a
    ///         misconfigured pool from running a no-op path silently.
    error HookNotImplemented();

    /// @notice Thrown when `unlockCallback` receives an unknown action
    ///         discriminator.
    error UnknownAction();

    // -----------------------------------------------------------------
    // onlyPoolManager modifier (replaces periphery `ImmutableState`)
    // -----------------------------------------------------------------

    /// @dev Single privilege check used by every V4 callback. The hook has
    ///      no other privileged callers. `M2Errors.OnlyPoolManager` matches
    ///      the selector used by the router for symmetry.
    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert M2Errors.OnlyPoolManager();
        _;
    }

    // -----------------------------------------------------------------
    // Constructor (paper §3.1 immutability; FINAL_REPORT §L1 fee-unit lock)
    // -----------------------------------------------------------------

    /// @param poolManager_ Uniswap V4 PoolManager.
    /// @param token_       M² token address (burn-authority #1 from the
    ///                     token's perspective).
    /// @param stable_      Backing stablecoin address.
    /// @param treasury_    Passive treasury contract address.
    /// @dev Mirrors `BaseHook`'s constructor: validates that the deployed
    ///      address encodes exactly the permission flags returned by
    ///      `getHookPermissions`. The CREATE2 salt must be mined to satisfy
    ///      this constraint; see `scripts/deploy/mine_hook_salt.ts`.
    constructor(
        IPoolManager poolManager_,
        address token_,
        address stable_,
        address treasury_
    ) {
        if (
            address(poolManager_) == address(0) ||
            token_ == address(0) ||
            stable_ == address(0) ||
            treasury_ == address(0)
        ) revert M2Errors.ZeroAddress();

        // FINAL_REPORT §L1: lock in the V4 fee-unit assumption at deploy time.
        // If V4 ever bumps `MAX_LP_FEE` to a different value, the constants
        // `BUY_FEE`/`SELL_FEE` would no longer mean 0.10%/3.00%; we refuse to
        // deploy in that scenario rather than silently mispricing.
        if (LPFeeLibrary.MAX_LP_FEE != M2Constants.V4_MAX_LP_FEE) {
            revert M2Errors.FeeUnitChanged();
        }

        POOL_MANAGER = poolManager_;
        _TOKEN = IM2Token(token_);
        _STABLE = IERC20(stable_);
        _TREASURY = IM2Treasury(treasury_);
        // Direction is derived from address sort, NOT hardcoded.
        // FINAL_REPORT §H4: the hook MUST work under both possible orderings.
        _STABLE_IS_CURRENCY0 = stable_ < token_;

        // Validate the deployed address encodes exactly the requested
        // permission bits. Reverts `HookAddressNotValid` from the V4
        // `Hooks` library otherwise. CREATE2 salt must be mined for
        // production; unit-test harnesses override `_validateHookAddress`
        // and use `vm.etch` to relocate runtime code to a flag-compliant
        // address.
        _validateHookAddress();
    }

    /// @notice Validates that `address(this)` encodes exactly the
    ///         permission bits returned by `getHookPermissions`. Production
    ///         deployments mine a CREATE2 salt s.t. the resulting address
    ///         has bottom-14 bits equal to `BEFORE_SWAP_FLAG = 0x0080`. The
    ///         function is `virtual` and `internal` so unit-test harnesses
    ///         may subclass `M2V4Hook` and override this hook to skip the
    ///         check (matching the periphery `BaseHook` pattern of a
    ///         `virtual` `validateHookAddress`). Production bytecode is
    ///         the un-overridden contract.
    /// @dev    Reverts `HookAddressNotValid(address(this))` from the V4
    ///         `Hooks` library if the address fails the V4 flag check.
    function _validateHookAddress() internal view virtual {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // =================================================================
    // V4 hook permissions
    // =================================================================

    /// @notice Returns the V4 permission struct. Only `beforeSwap` is enabled;
    ///         all other hook callbacks are disabled. `beforeSwapReturnDelta`
    ///         is also disabled — we only return a fee override, never a
    ///         delta.
    /// @dev    The CREATE2 salt must place this hook at an address whose
    ///         bottom 14 bits encode exactly this permission set
    ///         (`BEFORE_SWAP_FLAG = 1 << 7 = 0x0080`).
    function getHookPermissions()
        public
        pure
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =================================================================
    // IHooks — beforeSwap (the only enabled callback)
    // =================================================================

    /// @inheritdoc IHooks
    /// @notice Returns the dynamic fee override for this swap. The fee
    ///         depends on the INPUT currency, NOT on the pool's address sort:
    ///           - stable in  -> buy  -> `BUY_FEE  = 1_000`  (0.10%)
    ///           - token  in  -> sell -> `SELL_FEE = 30_000` (3.00%)
    ///         Paired CI fixtures (`deployCanonical_lowAddr.ts` and
    ///         `deployCanonical_highAddr.ts`) must both pass the full suite.
    /// @dev    The `OVERRIDE_FEE_FLAG` (0x400000) must be ORed in for V4 to
    ///         apply the returned fee in place of the pool's static fee. We
    ///         also assert the pool key matches the configured pool so a
    ///         malicious operator cannot route a fee override through a
    ///         pool we don't own.
    function beforeSwap(
        address /* sender */,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata /* hookData */
    ) external view onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        if (!_initialized) revert NotInitialized();
        _requirePoolKeyMatch(key);

        // Direction derivation: which currency is the SWAP INPUT?
        //   zeroForOne == true  -> input = currency0
        //   zeroForOne == false -> input = currency1
        // The mapping from currency-0/1 to stable/token is captured once at
        // construction time in `_STABLE_IS_CURRENCY0`.
        bool stableInput = params.zeroForOne
            ? _STABLE_IS_CURRENCY0
            : !_STABLE_IS_CURRENCY0;

        uint24 fee = stableInput ? M2Constants.BUY_FEE : M2Constants.SELL_FEE;

        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            fee | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    // =================================================================
    // IHooks — disabled callbacks (revert defensively)
    // =================================================================
    //
    // V4 only invokes a hook callback if the corresponding permission flag
    // is set in the hook's address. We disable every callback except
    // `beforeSwap` via `getHookPermissions`, so V4 should never call any of
    // these. Reverting `HookNotImplemented` is a belt-and-suspenders defense
    // against (a) an upstream V4 bug, (b) an EOA / wrong caller trying to
    // invoke the callback directly. Each callback is `onlyPoolManager`-gated
    // and immediately reverts; no logic runs.

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, int128) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    // =================================================================
    // Pool initialization + LP seeding (one-shot)
    // =================================================================

    /// @notice One-shot pool + LP initializer. Called by the genesis factory
    ///         (or any seeder) AFTER the caller has transferred the initial
    ///         token and stable seed to this contract. The hook then:
    ///           1. records the pool key and chosen ticks,
    ///           2. calls `poolManager.initialize(key, sqrtPriceX96)`,
    ///           3. acquires the manager lock via `unlock`,
    ///           4. inside `unlockCallback`: `modifyLiquidity(+liquidity)`,
    ///              settles the token + stable owed deltas with `sync /
    ///              transfer / settle`.
    ///         Calling this function a second time reverts with
    ///         `AlreadyInitialized`.
    /// @param key_          The V4 pool key. MUST have `hooks == this`, `fee
    ///                      == DYNAMIC_FEE_FLAG`, and currencies `{token,
    ///                      stable}` in either order.
    /// @param sqrtPriceX96  Initial V4 sqrt price (Q64.96).
    /// @param liquidity     Liquidity to add as a single full-range position
    ///                      (`[minUsableTick(spacing), maxUsableTick(spacing)]`).
    ///                      Computed off-chain from the desired `(Lt0, Ls0)`
    ///                      seed via `LiquidityAmounts.getLiquidityForAmounts`.
    /// @dev The function is intentionally permissionless: any caller can
    ///      seed the pool, but the call must succeed atomically — partial
    ///      seeding reverts. In the genesis factory flow, only the factory
    ///      holds the seed funds and is the only realistic caller.
    /// @dev Phase 5: only the genesis factory should call this; the one-shot
    ///      `_initialized` flag below is the structural protection — any
    ///      subsequent call reverts with `AlreadyInitialized`, so the
    ///      worst-case front-runner can only deny the factory its preferred
    ///      `(sqrtPriceX96, liquidity)` once before the seed funds are
    ///      forfeit. The Phase 5 factory batches the seed transfer +
    ///      `initializePool` in one tx so this race window collapses.
    function initializePool(
        PoolKey calldata key_,
        uint160 sqrtPriceX96,
        uint128 liquidity
    ) external {
        if (_initialized) revert AlreadyInitialized();

        // The key's hook must equal this contract; the key's currencies must
        // match the configured token/stable pair (in either order); the fee
        // field must be exactly the dynamic-fee flag.
        if (address(key_.hooks) != address(this)) revert M2Errors.InvalidPool();
        if (key_.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) revert M2Errors.InvalidPool();
        _requireKeyCurrenciesMatch(key_);

        _poolKey = key_;
        _tickLower = TickMath.minUsableTick(key_.tickSpacing);
        _tickUpper = TickMath.maxUsableTick(key_.tickSpacing);
        _initialized = true;

        // Initialize the V4 pool. Does NOT require an unlock.
        POOL_MANAGER.initialize(key_, sqrtPriceX96);

        // Add the protocol-owned LP position via the standard unlock pattern.
        // The callback returns nothing meaningful for init.
        POOL_MANAGER.unlock(
            abi.encode(_ACTION_INIT_LP, abi.encode(liquidity))
        );
    }

    // =================================================================
    // collectFees — permissionless fee realization (paper §3.5)
    // =================================================================

    /// @notice Realize accrued V4 fees for the protocol-owned LP position
    ///         and distribute per the paper §3.5 0.25%/99.75% rule:
    ///         - stable side: 99.75% to treasury, 0.25% to caller
    ///         - token  side: 99.75% burned,    0.25% to caller
    ///         Conservation: `stableBounty + stableToTreasury == stableRealized`,
    ///                       `tokenBounty + tokenBurned       == tokenRealized`.
    ///         Enforced by subtraction (no stranded wei).
    /// @return stableOut Total stable-side fees realized.
    /// @return tokenOut  Total token-side fees realized.
    function collectFees()
        external
        returns (uint256 stableOut, uint256 tokenOut)
    {
        if (!_initialized) revert NotInitialized();

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(_ACTION_COLLECT_FEES, abi.encode(msg.sender))
        );
        (stableOut, tokenOut) = abi.decode(result, (uint256, uint256));
    }

    // =================================================================
    // V4 unlock callback (PoolManager-only)
    // =================================================================

    /// @inheritdoc IUnlockCallback
    /// @dev Multiplexes by action discriminator. Only the configured V4
    ///      PoolManager may invoke this function; any other caller reverts
    ///      with `OnlyPoolManager`. Re-entry into this function from another
    ///      address during the unlock window is therefore impossible.
    function unlockCallback(bytes calldata data)
        external
        override
        onlyPoolManager
        returns (bytes memory)
    {
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action == _ACTION_INIT_LP) {
            uint128 liquidity = abi.decode(payload, (uint128));
            _executeInitLp(liquidity);
            return bytes("");
        }
        if (action == _ACTION_COLLECT_FEES) {
            address caller = abi.decode(payload, (address));
            (uint256 stableRealized, uint256 tokenRealized) =
                _executeCollectFees(caller);
            return abi.encode(stableRealized, tokenRealized);
        }
        revert UnknownAction();
    }

    // =================================================================
    // Internal: unlock-callback bodies
    // =================================================================

    /// @dev Add the seed liquidity to the protocol-owned full-range position.
    ///      The hook holds the token+stable seed at this point (transferred
    ///      by the caller before `initializePool`). Settles both owed
    ///      currencies in the standard V4 sync / transfer / settle pattern.
    function _executeInitLp(uint128 liquidity) internal {
        PoolKey memory key = _poolKey;
        (BalanceDelta callerDelta, /* feesAccrued */) =
            POOL_MANAGER.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: _tickLower,
                    tickUpper: _tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );

        // Adding liquidity yields negative deltas on both sides (we owe).
        int128 d0 = BalanceDeltaLibrary.amount0(callerDelta);
        int128 d1 = BalanceDeltaLibrary.amount1(callerDelta);

        if (d0 < 0) _settleOwed(key.currency0, uint256(uint128(-d0)));
        if (d1 < 0) _settleOwed(key.currency1, uint256(uint128(-d1)));

        // A positive delta during LP-seed is unexpected (no fees yet);
        // surface it loudly rather than silently swallowing.
        if (d0 > 0) _takeOwed(key.currency0, uint256(uint128(d0)));
        if (d1 > 0) _takeOwed(key.currency1, uint256(uint128(d1)));
    }

    /// @dev Realize fees by calling `modifyLiquidity(0, ...)` and distribute
    ///      per the 0.25/99.75 rule. The full body runs inside the V4 lock,
    ///      so the `take`/`safeTransfer`/`burn` calls happen atomically with
    ///      the fee realization.
    function _executeCollectFees(address caller)
        internal
        returns (uint256 stableRealized, uint256 tokenRealized)
    {
        PoolKey memory key = _poolKey;
        bool stableIs0 = _STABLE_IS_CURRENCY0;

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) =
            POOL_MANAGER.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: _tickLower,
                    tickUpper: _tickUpper,
                    liquidityDelta: 0,
                    salt: bytes32(0)
                }),
                ""
            );
        // For `liquidityDelta == 0`, `callerDelta` equals `feesAccrued`
        // exactly: the only credit is the realized fee. We use `callerDelta`
        // for the take amounts (it is the value the manager will reconcile
        // against on settle). `feesAccrued` is preserved for parity with the
        // V4 dev note in `docs/v4_model_correspondence.md`; the V4-core dev
        // note on `modifyLiquidity` warns that single-LP pools can inflate
        // `feesAccrued` via self-donations, so we don't use it for accounting.
        feesAccrued; // silence unused-warning

        int128 c0 = BalanceDeltaLibrary.amount0(callerDelta);
        int128 c1 = BalanceDeltaLibrary.amount1(callerDelta);

        // Fees realize as nonneg deltas. A negative delta here would be a V4
        // bug or an adversarial pool — refuse to proceed.
        if (c0 < 0 || c1 < 0) revert M2Errors.UnexpectedSwapSign();

        uint256 d0u = uint256(uint128(c0));
        uint256 d1u = uint256(uint128(c1));

        (stableRealized, tokenRealized) =
            stableIs0 ? (d0u, d1u) : (d1u, d0u);

        // Take both sides into this contract before distributing. Skip
        // zero-amount takes to avoid the V4 manager's NonzeroDeltaCount
        // accounting cost.
        if (stableRealized > 0) {
            _takeOwed(
                stableIs0 ? key.currency0 : key.currency1,
                stableRealized
            );
        }
        if (tokenRealized > 0) {
            _takeOwed(
                stableIs0 ? key.currency1 : key.currency0,
                tokenRealized
            );
        }

        // Compute the 0.25%/99.75% distribution. Floor-rounding the bounty
        // is protocol-protective (caller gets the floor share; protocol
        // keeps the residual). Conservation is exact by subtraction —
        // FINAL_REPORT §L4 no-stranded-wei.
        uint256 stableBounty =
            (stableRealized * M2Constants.CALLER_BOUNTY_BPS) /
                M2Constants.BPS_DENOMINATOR;
        uint256 stableToTreasury = stableRealized - stableBounty;
        uint256 tokenBounty =
            (tokenRealized * M2Constants.CALLER_BOUNTY_BPS) /
                M2Constants.BPS_DENOMINATOR;
        uint256 tokenToBurn = tokenRealized - tokenBounty;

        // Distribute stable side (SafeERC20 normalizes non-standard returns).
        if (stableBounty > 0) _STABLE.safeTransfer(caller, stableBounty);
        if (stableToTreasury > 0) {
            _STABLE.safeTransfer(address(_TREASURY), stableToTreasury);
        }

        // Distribute token side. The 99.75% share is burned via the M2Token's
        // three-role burn authority (this contract is burn-authority #1).
        if (tokenBounty > 0) {
            IERC20(address(_TOKEN)).safeTransfer(caller, tokenBounty);
        }
        if (tokenToBurn > 0) {
            _TOKEN.burnFromAuthorized(address(this), tokenToBurn);
        }

        emit FeesCollected(
            caller,
            stableRealized,
            tokenRealized,
            stableBounty,
            tokenBounty,
            tokenToBurn,
            stableToTreasury
        );
    }

    // =================================================================
    // Internal helpers (sync/settle/take)
    // =================================================================

    /// @dev Settle a currency we owe to the PoolManager: sync, transfer the
    ///      ERC20 amount to the manager, then `settle()`. Used during LP seed.
    function _settleOwed(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        POOL_MANAGER.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(
            address(POOL_MANAGER),
            amount
        );
        POOL_MANAGER.settle();
    }

    /// @dev Take a credited currency out of the PoolManager and into this
    ///      contract. Used during fee realization and as a defensive path
    ///      during LP seed.
    function _takeOwed(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        POOL_MANAGER.take(currency, address(this), amount);
    }

    // =================================================================
    // Internal helpers (pool-key validation)
    // =================================================================

    /// @dev Reverts unless `key` has currency0/1 equal to the configured
    ///      token/stable in either order. Used by `initializePool` BEFORE
    ///      the key is stored.
    function _requireKeyCurrenciesMatch(PoolKey calldata key) internal view {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool ok;
        if (_STABLE_IS_CURRENCY0) {
            ok = c0 == address(_STABLE) && c1 == address(_TOKEN);
        } else {
            ok = c0 == address(_TOKEN) && c1 == address(_STABLE);
        }
        if (!ok) revert M2Errors.InvalidPool();
    }

    /// @dev Reverts unless `key` deep-equals the stored pool key. Used by
    ///      `beforeSwap` to refuse pools the hook does not own. We compare
    ///      currency0/1 + hooks + tickSpacing + fee fields.
    function _requirePoolKeyMatch(PoolKey calldata key) internal view {
        PoolKey memory stored = _poolKey;
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(stored.currency0) ||
            Currency.unwrap(key.currency1) != Currency.unwrap(stored.currency1) ||
            address(key.hooks) != address(stored.hooks) ||
            key.tickSpacing != stored.tickSpacing ||
            key.fee != stored.fee
        ) revert M2Errors.InvalidPool();
    }

    // =================================================================
    // View surface (mirrors `IM2Hook` — not inherited because we expose
    // `POOL_MANAGER` as `IPoolManager`, not `address`)
    // =================================================================

    /// @notice Immutable V4 PoolManager address (matches `IM2Hook` ABI).
    function poolManager() external view returns (address) {
        return address(POOL_MANAGER);
    }

    /// @notice Immutable M² token address (one of the three burn authorities).
    function token() external view returns (address) {
        return address(_TOKEN);
    }

    /// @notice Immutable backing stablecoin address.
    function stable() external view returns (address) {
        return address(_STABLE);
    }

    /// @notice Immutable treasury custody contract address.
    function treasury() external view returns (address) {
        return address(_TREASURY);
    }

    /// @notice Whether the backing stable is currency0 in the pool key.
    ///         Precomputed at construction time from the V4 address sort.
    function stableIsCurrency0() external view returns (bool) {
        return _STABLE_IS_CURRENCY0;
    }

    /// @notice Returns the V4 pool key the hook owns. Reverts before
    ///         `initializePool` has run.
    function poolKey() external view returns (PoolKey memory) {
        if (!_initialized) revert NotInitialized();
        return _poolKey;
    }

    /// @notice Whether the pool has been initialized.
    function isInitialized() external view returns (bool) {
        return _initialized;
    }

    /// @notice Lower tick of the protocol-owned full-range position.
    function tickLower() external view returns (int24) {
        return _tickLower;
    }

    /// @notice Upper tick of the protocol-owned full-range position.
    function tickUpper() external view returns (int24) {
        return _tickUpper;
    }
}
