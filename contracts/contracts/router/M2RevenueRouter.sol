// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IM2Token} from "../interfaces/IM2Token.sol";
import {IM2Treasury} from "../interfaces/IM2Treasury.sol";
import {IM2RevenueRouter} from "../interfaces/IM2RevenueRouter.sol";
import {IM2Events} from "../libraries/M2Events.sol";
import {M2Errors} from "../libraries/M2Errors.sol";

/// @title M2RevenueRouter
/// @author M² / Monotonic Math
/// @notice Single-function revenue router. Pulls `stableAmount` from the
///         immutable authorized depositor, sends `floor(stableAmount / 2)` to
///         the treasury, uses the remaining `ceil(stableAmount / 2)` to buy
///         M² tokens from the V4 LP via the standard unlock/swap/settle/take
///         flash-accounting flow, and burns the tokens received.
/// @dev    Implements `IUnlockCallback` directly: V4's `PoolManager.unlock`
///         calls back into `unlockCallback` on this contract. The router
///         contains no admin keys, no setters, no governance hook, and no
///         pause switch. Every privilege check is a `require(msg.sender == X)`
///         against an immutable. Paper §3.5; FINAL_REPORT §H4 (direction must
///         be derived, not hardcoded).
contract M2RevenueRouter is IM2RevenueRouter, IM2Events, IUnlockCallback {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Immutable wiring
    // -----------------------------------------------------------------

    /// @dev Backing stablecoin.
    IERC20 private immutable _STABLE;

    /// @dev The M² token (target of the buy-and-burn leg).
    IM2Token private immutable _TOKEN;

    /// @dev Passive custody treasury contract receiving the floor half.
    IM2Treasury private immutable _TREASURY;

    /// @dev The immutable authorized revenue depositor. Only address that
    ///      may call `routeRevenue`.
    address private immutable _DEPOSITOR;

    /// @dev Uniswap V4 PoolManager. The only address allowed to invoke
    ///      `unlockCallback` on this contract.
    IPoolManager private immutable _POOL_MANAGER;

    /// @dev The V4 hook owning the protocol's LP position. Stored for
    ///      introspection / event correspondence; used in the constructor
    ///      to validate the pool key matches the configured hook.
    address private immutable _HOOK;

    /// @dev Cached direction flag: `true` iff the configured backing stable is
    ///      currency0 in the pool key. Computed once in the constructor from
    ///      the V4 pool-key address sort. Paper FINAL_REPORT §H4 forbids
    ///      hardcoding zeroForOne; we precompute from address comparison.
    bool private immutable _STABLE_IS_CURRENCY0;

    // -----------------------------------------------------------------
    // Pool key (effectively immutable: written once in constructor; no setter)
    // -----------------------------------------------------------------

    /// @dev `PoolKey` cannot be declared `immutable` (contains struct fields
    ///      and a user-defined-value type), so we store it in a single storage
    ///      slot group set exactly once during construction. No function in
    ///      this contract writes to these fields after the constructor.
    PoolKey private _poolKey;

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    /// @param stable_      Backing stablecoin address.
    /// @param token_       M² token address.
    /// @param treasury_    Treasury contract address.
    /// @param depositor_   Immutable authorized revenue depositor.
    /// @param poolManager_ V4 PoolManager address.
    /// @param hook_        V4 hook contract owning the LP position.
    /// @param poolKey_     The V4 pool key for the M²/Stable pool. MUST have
    ///                     `hooks == hook_`, `fee == DYNAMIC_FEE_FLAG`, and
    ///                     currencies `{token_, stable_}`.
    constructor(
        address stable_,
        address token_,
        address treasury_,
        address depositor_,
        address poolManager_,
        address hook_,
        PoolKey memory poolKey_
    ) {
        if (
            stable_ == address(0) ||
            token_ == address(0) ||
            treasury_ == address(0) ||
            depositor_ == address(0) ||
            poolManager_ == address(0) ||
            hook_ == address(0)
        ) revert M2Errors.ZeroAddress();

        // The pool key's hook MUST equal the configured hook address.
        if (address(poolKey_.hooks) != hook_) revert M2Errors.InvalidPool();

        // The pool MUST be a dynamic-fee pool. V4 encodes that as the high
        // bit (0x800000) being set on the `fee` field. Per V4 semantics the
        // field must equal exactly `DYNAMIC_FEE_FLAG` (a static fee with the
        // high bit set is not a valid pool).
        if (poolKey_.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) {
            revert M2Errors.InvalidPool();
        }

        // The pool's two currencies MUST be the protocol's token and stable
        // in either ordering. The constructor caches the direction flag so
        // `unlockCallback` does not have to recompute address order at swap
        // time.
        address c0 = Currency.unwrap(poolKey_.currency0);
        address c1 = Currency.unwrap(poolKey_.currency1);
        bool stableIs0;
        if (c0 == stable_ && c1 == token_) {
            stableIs0 = true;
        } else if (c0 == token_ && c1 == stable_) {
            stableIs0 = false;
        } else {
            revert M2Errors.InvalidPool();
        }

        _STABLE = IERC20(stable_);
        _TOKEN = IM2Token(token_);
        _TREASURY = IM2Treasury(treasury_);
        _DEPOSITOR = depositor_;
        _POOL_MANAGER = IPoolManager(poolManager_);
        _HOOK = hook_;
        _STABLE_IS_CURRENCY0 = stableIs0;

        _poolKey = poolKey_;
    }

    // -----------------------------------------------------------------
    // IM2RevenueRouter view surface
    // -----------------------------------------------------------------

    /// @inheritdoc IM2RevenueRouter
    function stable() external view returns (address) {
        return address(_STABLE);
    }

    /// @inheritdoc IM2RevenueRouter
    function token() external view returns (address) {
        return address(_TOKEN);
    }

    /// @inheritdoc IM2RevenueRouter
    function treasury() external view returns (address) {
        return address(_TREASURY);
    }

    /// @inheritdoc IM2RevenueRouter
    function depositor() external view returns (address) {
        return _DEPOSITOR;
    }

    /// @inheritdoc IM2RevenueRouter
    function poolManager() external view returns (address) {
        return address(_POOL_MANAGER);
    }

    /// @inheritdoc IM2RevenueRouter
    function hook() external view returns (address) {
        return _HOOK;
    }

    /// @notice Returns the immutable V4 pool key the router targets.
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Returns `true` iff the backing stable is `currency0` in the
    ///         pool key (precomputed from the V4 address sort at construction).
    function stableIsCurrency0() external view returns (bool) {
        return _STABLE_IS_CURRENCY0;
    }

    // -----------------------------------------------------------------
    // routeRevenue (depositor-only)
    // -----------------------------------------------------------------

    /// @inheritdoc IM2RevenueRouter
    /// @dev CEI: pull stable -> transfer treasury half -> swap (effects in
    ///      callback) -> burn the bought tokens. The slippage check is
    ///      enforced inside `unlockCallback` and re-checked here as
    ///      belt-and-suspenders so the final burn cannot occur with
    ///      `tokensReceived < minTokensOut`.
    function routeRevenue(uint256 stableAmount, uint256 minTokensOut)
        external
        returns (uint256 treasuryIn, uint256 stableUsedForBuy, uint256 tokensBurned)
    {
        if (msg.sender != _DEPOSITOR) revert M2Errors.UnauthorizedDepositor();
        if (stableAmount == 0) revert M2Errors.ZeroAmount();

        // 50/50 split: floor-to-treasury, ceiling-to-buy. Matches paper §3.5.
        treasuryIn = stableAmount / 2;
        stableUsedForBuy = stableAmount - treasuryIn;

        // Pull the full amount from depositor; SafeERC20 normalizes
        // non-standard ERC20 return values.
        _STABLE.safeTransferFrom(msg.sender, address(this), stableAmount);

        // Send the floor half to treasury.
        _STABLE.safeTransfer(address(_TREASURY), treasuryIn);

        // Acquire the V4 lock and execute the swap inside `unlockCallback`.
        // The callback returns the abi-encoded `tokensReceived`.
        bytes memory callbackResult = _POOL_MANAGER.unlock(
            abi.encode(stableUsedForBuy, minTokensOut)
        );
        uint256 tokensReceived = abi.decode(callbackResult, (uint256));

        // Defense-in-depth slippage check.
        if (tokensReceived < minTokensOut) revert M2Errors.SlippageExceeded();

        // Burn the bought tokens. Router is one of the three burn authorities.
        _TOKEN.burnFromAuthorized(address(this), tokensReceived);
        tokensBurned = tokensReceived;

        emit RevenueRouted(stableAmount, treasuryIn, stableUsedForBuy, tokensBurned);
    }

    // -----------------------------------------------------------------
    // V4 unlock callback (PoolManager-only)
    // -----------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    /// @dev Only invoked transitively from `routeRevenue` via
    ///      `PoolManager.unlock`. The function enforces `msg.sender ==
    ///      _POOL_MANAGER`. Inside the callback we:
    ///        1. swap stable -> token via `PoolManager.swap`;
    ///        2. settle the stable side (we owe) via sync + transfer + settle;
    ///        3. take the token side (we are owed) into the router.
    ///      Returns abi-encoded `tokensReceived` for the outer `routeRevenue`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(_POOL_MANAGER)) revert M2Errors.OnlyPoolManager();

        (uint256 stableUsedForBuy, uint256 minTokensOut) = abi.decode(
            data,
            (uint256, uint256)
        );

        PoolKey memory key = _poolKey;
        bool stableIs0 = _STABLE_IS_CURRENCY0;

        // Direction:
        //   - stable -> token via stable as input
        //   - if stable is currency0, zeroForOne = true; price moves down.
        //   - if stable is currency1, zeroForOne = false; price moves up.
        bool zeroForOne = stableIs0;

        // Negative `amountSpecified` = exactInput of `stableUsedForBuy`.
        int256 amountSpecified = -int256(stableUsedForBuy);

        // No price-limit (slippage protection is `minTokensOut` below).
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;

        BalanceDelta swapDelta = _POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        Currency stableCurrency = stableIs0 ? key.currency0 : key.currency1;
        Currency tokenCurrency = stableIs0 ? key.currency1 : key.currency0;

        // Resolve the deltas for each side. With `zeroForOne = stableIs0`,
        // the router's debit is on stableCurrency (negative delta) and
        // credit is on tokenCurrency (positive delta).
        int128 stableDeltaI128 = stableIs0
            ? BalanceDeltaLibrary.amount0(swapDelta)
            : BalanceDeltaLibrary.amount1(swapDelta);
        int128 tokenDeltaI128 = stableIs0
            ? BalanceDeltaLibrary.amount1(swapDelta)
            : BalanceDeltaLibrary.amount0(swapDelta);

        if (stableDeltaI128 > 0) revert M2Errors.UnexpectedSwapSign();
        if (tokenDeltaI128 < 0) revert M2Errors.UnexpectedSwapSign();

        // Settle the stable side (router owes). Sync, transfer, then settle.
        // For exact-input swaps with no hook delta, |stableDelta| ==
        // stableUsedForBuy; we use the actual delta to be robust against
        // any future hook-delta extensions.
        uint256 stableOwed = uint256(uint128(-stableDeltaI128));
        _POOL_MANAGER.sync(stableCurrency);
        IERC20(Currency.unwrap(stableCurrency)).safeTransfer(
            address(_POOL_MANAGER),
            stableOwed
        );
        _POOL_MANAGER.settle();

        // Take the token output to the router.
        uint256 tokensReceived = uint256(uint128(tokenDeltaI128));
        if (tokensReceived < minTokensOut) revert M2Errors.SlippageExceeded();
        _POOL_MANAGER.take(tokenCurrency, address(this), tokensReceived);

        return abi.encode(tokensReceived);
    }
}
