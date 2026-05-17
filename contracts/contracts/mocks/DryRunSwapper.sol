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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev Minimal pool-key getter on M2V4Hook (not in IM2Hook to avoid
///      exposing the V4 type in the protocol interface).
interface IM2HookPoolKey {
    function poolKey() external view returns (PoolKey memory);
}

/// @title DryRunSwapper
/// @author M² / Monotonic Math
/// @notice TEST-ONLY swap router used by `02_dry_run_sepolia.ts` and the
///         Sepolia end-to-end smoke test to exercise the hook's
///         beforeSwap fee logic via real V4 PoolManager swaps. Mirrors the
///         minimal surface of a V4 swap router: a caller calls `swap(...)`,
///         we unlock the manager, perform the swap, settle/take, and
///         deliver the output to the caller.
/// @dev    NOT for production use. This contract is intentionally NOT
///         immutable, has no admin protections beyond the standard
///         onlyPoolManager check on `unlockCallback`, and is wired
///         post-genesis so it is fully external to the four immutable
///         protocol contracts. The plan permits a separate test swap
///         router (or a direct PoolManager-with-unlock-callback) for the
///         Sepolia e2e flow.
contract DryRunSwapper is IUnlockCallback {
    using SafeERC20 for IERC20;

    /// @notice Uniswap V4 PoolManager.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Backing stablecoin address.
    IERC20 public immutable STABLE;

    /// @notice M² token address.
    IERC20 public immutable TOKEN;

    /// @notice The M2 hook owning the LP position. Used to fetch the
    ///         canonical pool key at swap time (the swap helper does not
    ///         hold a copy of the key; it queries the hook).
    address public immutable HOOK;

    /// @dev `true` iff `STABLE` is currency0 in the pool key. Resolved at
    ///      construction via address comparison (matches the hook).
    bool private immutable _STABLE_IS_CURRENCY0;

    error OnlyPoolManager();
    error UnexpectedSwapSign();

    constructor(
        address poolManager_,
        address stable_,
        address token_,
        address hook_
    ) {
        require(
            poolManager_ != address(0) &&
                stable_ != address(0) &&
                token_ != address(0) &&
                hook_ != address(0),
            "DryRunSwapper: zero address"
        );
        POOL_MANAGER = IPoolManager(poolManager_);
        STABLE = IERC20(stable_);
        TOKEN = IERC20(token_);
        HOOK = hook_;
        _STABLE_IS_CURRENCY0 = stable_ < token_;
    }

    /// @notice Execute a swap. The caller must have approved this contract
    ///         for `amountIn` of the input currency.
    /// @param  stableIn  true ⇒ swap stable → token (LP buy);
    ///                   false ⇒ swap token → stable (LP sell).
    /// @param  amountIn  Amount of the input currency.
    /// @return amountOut Amount of the output currency delivered to caller.
    function swap(bool stableIn, uint256 amountIn)
        external
        returns (uint256 amountOut)
    {
        IERC20 inputToken = stableIn ? STABLE : TOKEN;
        // Pull input from caller.
        inputToken.safeTransferFrom(msg.sender, address(this), amountIn);

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(msg.sender, stableIn, amountIn)
        );
        amountOut = abi.decode(result, (uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data)
        external
        returns (bytes memory)
    {
        if (msg.sender != address(POOL_MANAGER)) revert OnlyPoolManager();
        (address caller, bool stableIn, uint256 amountIn) = abi.decode(
            data,
            (address, bool, uint256)
        );

        // Direction: `zeroForOne = inputIsCurrency0`.
        bool stableIs0 = _STABLE_IS_CURRENCY0;
        bool zeroForOne = stableIn ? stableIs0 : !stableIs0;

        // Exact-input swap: negative amountSpecified.
        int256 amountSpecified = -int256(amountIn);
        uint160 sqrtPriceLimitX96 = zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;

        // Fetch the pool key from the hook (single source of truth).
        PoolKey memory key = IM2HookPoolKey(HOOK).poolKey();

        BalanceDelta swapDelta = POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        // Identify input/output currencies and deltas.
        Currency inputCurrency;
        Currency outputCurrency;
        int128 inputDelta;
        int128 outputDelta;
        if (zeroForOne) {
            inputCurrency = key.currency0;
            outputCurrency = key.currency1;
            inputDelta = BalanceDeltaLibrary.amount0(swapDelta);
            outputDelta = BalanceDeltaLibrary.amount1(swapDelta);
        } else {
            inputCurrency = key.currency1;
            outputCurrency = key.currency0;
            inputDelta = BalanceDeltaLibrary.amount1(swapDelta);
            outputDelta = BalanceDeltaLibrary.amount0(swapDelta);
        }

        if (inputDelta > 0) revert UnexpectedSwapSign();
        if (outputDelta < 0) revert UnexpectedSwapSign();

        uint256 inputOwed = uint256(uint128(-inputDelta));
        uint256 outputAmount = uint256(uint128(outputDelta));

        // Settle input side: sync, transfer, settle.
        POOL_MANAGER.sync(inputCurrency);
        IERC20(Currency.unwrap(inputCurrency)).safeTransfer(
            address(POOL_MANAGER),
            inputOwed
        );
        POOL_MANAGER.settle();

        // Take output side and forward to the caller.
        POOL_MANAGER.take(outputCurrency, caller, outputAmount);

        // Silence unused-variable warning.
        outputCurrency;
        return abi.encode(outputAmount);
    }
}
