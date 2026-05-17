// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {M2Constants} from "../libraries/M2Constants.sol";

/// @title MockAMM — Phase 3 stand-in for the Uniswap V4 PoolManager + LP
/// @author M² / Monotonic Math
/// @notice TEST-ONLY constant-product AMM that implements just enough of the
///         V4 `IPoolManager` surface (`unlock`, `swap`, `sync`, `settle`,
///         `take`, `initialize`, `modifyLiquidity`) for the real
///         {M2RevenueRouter} bytecode to drive against it. Tracks reserves
///         `(Lt, Ls)` and asymmetric per-direction fee accumulators
///         `(Phi_t, Phi_s)` mirroring the paper's §4.1 state tuple. Replaced
///         by the real V4 PoolManager + {M2V4Hook} in Phase 4.
/// @dev    NOT deployed on any real network. Free `mint`/setter functions are
///         allowed because this contract is test-only. Phase 4 replacement
///         eliminates these by routing through real V4 PoolManager + hook.
///
///         Architectural decision: MockAMM acts as both the V4 PoolManager
///         AND the LP. The real router calls `_POOL_MANAGER.unlock(...)`,
///         so MockAMM must own the unlock/callback contract; combining the
///         LP reserves into the same contract keeps the test surface flat.
///
///         Fee folding (matches `M2ReferenceModel.ts` "with-fees" mode):
///           - Stable-input swap (buy): `feeIn = floor(X * BUY_FEE / 1_000_000)`
///             goes to `Phi_s`; `Xnet = X - feeIn` hits the curve.
///           - Token-input  swap (sell): `feeIn = floor(N * SELL_FEE / 1_000_000)`
///             goes to `Phi_t`; `Nnet = N - feeIn` hits the curve.
///         Rounding direction: `LtNew = k / LsNew` (floor) — matches V4
///         SwapMath exact-input semantics; protocol-protective.
contract MockAMM {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------

    error AlreadyInitialized();
    error NotInitialized();
    error AlreadyUnlocked();
    error ManagerLocked();
    error UnexpectedReentry();
    error CurrencyNotSettled();
    error InvalidCurrency();
    error InvalidPool();
    error UnauthorizedHook();
    error ZeroLiquidity();
    error InsufficientLiquidity();

    // -----------------------------------------------------------------
    // Immutable wiring
    // -----------------------------------------------------------------

    /// @notice Address of the backing stable.
    IERC20 public immutable STABLE;

    /// @notice Address of the M² token.
    IERC20 public immutable M2_TOKEN;

    /// @notice Address of the hook contract authorized to drain accumulators.
    ///         Test-only — Phase 4 replaces this with V4 modifyLiquidity flow.
    address public immutable HOOK;

    /// @notice `true` iff `address(stable) < address(token)`.
    bool public immutable STABLE_IS_CURRENCY0;

    // -----------------------------------------------------------------
    // State — pool reserves and fee accumulators (paper §4.1)
    // -----------------------------------------------------------------

    /// @notice LP token reserve `L_t` (paper §4.1). Same units as `S`.
    uint256 public Lt;
    /// @notice LP stable reserve `L_s` (paper §4.1). Same units as `T`.
    uint256 public Ls;
    /// @notice Unrealized token-side fee accumulator `Φ_t`. Burns at collectFees.
    uint256 public PhiT;
    /// @notice Unrealized stable-side fee accumulator `Φ_s`. Forwards to treasury.
    uint256 public PhiS;

    /// @notice Whether the pool has been initialized with reserves.
    bool public initialized;

    // -----------------------------------------------------------------
    // Transient flash-accounting state (set during `unlock`)
    // -----------------------------------------------------------------

    /// @dev The address currently holding the unlock lock. `address(0)` when locked.
    address private _unlockedBy;
    /// @dev Per-(currency, address) delta accrued during the current unlock window.
    ///      Positive delta = owed TO the address (credit); negative = address owes us.
    mapping(address => mapping(address => int256)) private _delta;
    /// @dev Snapshot of the currency balance taken by `sync` for the next `settle`.
    mapping(address => uint256) private _syncedBalance;
    /// @dev The currency that was last `sync`'d (settle pulls from this slot).
    address private _syncedCurrency;
    /// @dev Set of currencies that have a non-zero delta in the current unlock window.
    mapping(address => bool) private _hasDelta;

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    /// @param stable_ Backing stable ERC20.
    /// @param token_  M² token ERC20.
    /// @param hook_   Authorized hook (test-only): the only address allowed
    ///                to call `drainAccumulators`.
    constructor(address stable_, address token_, address hook_) {
        require(stable_ != address(0), "MockAMM: stable=0");
        require(token_ != address(0), "MockAMM: token=0");
        require(hook_ != address(0), "MockAMM: hook=0");
        STABLE = IERC20(stable_);
        M2_TOKEN = IERC20(token_);
        HOOK = hook_;
        STABLE_IS_CURRENCY0 = stable_ < token_;
    }

    // =================================================================
    // V4-like surface invoked by the real M2RevenueRouter
    // =================================================================

    /// @notice Mimics `IPoolManager.unlock`: acquires the per-tx lock,
    ///         calls back into `msg.sender.unlockCallback(data)`, asserts
    ///         all currency deltas net to zero at the end, releases the
    ///         lock, and returns the callback's return value.
    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (_unlockedBy != address(0)) revert AlreadyUnlocked();
        _unlockedBy = msg.sender;

        result = IUnlockCallback(msg.sender).unlockCallback(data);

        // V4 invariant: all currency deltas for every address that touched
        // the manager during the unlock window must net to zero.
        address[2] memory tracked = [address(STABLE), address(M2_TOKEN)];
        for (uint256 i = 0; i < tracked.length; ++i) {
            if (_delta[tracked[i]][msg.sender] != 0) revert CurrencyNotSettled();
            // Clear any sync-state residue for cleanliness.
        }
        _syncedCurrency = address(0);
        _unlockedBy = address(0);
    }

    /// @notice Mimics `IPoolManager.sync`: snapshots the manager's balance of
    ///         `currency` so the next `settle` can compute the deposit amount.
    function sync(Currency currency) external {
        if (_unlockedBy == address(0)) revert ManagerLocked();
        address cur = Currency.unwrap(currency);
        if (cur != address(STABLE) && cur != address(M2_TOKEN)) revert InvalidCurrency();
        _syncedCurrency = cur;
        _syncedBalance[cur] = IERC20(cur).balanceOf(address(this));
    }

    /// @notice Mimics `IPoolManager.settle`: credits the unlocker with the
    ///         balance delta since the last `sync` of the synced currency.
    ///         Returns the amount paid in (positive integer).
    function settle() external payable returns (uint256 paid) {
        if (_unlockedBy == address(0)) revert ManagerLocked();
        address cur = _syncedCurrency;
        if (cur == address(0)) revert InvalidCurrency();
        uint256 prev = _syncedBalance[cur];
        uint256 nowBal = IERC20(cur).balanceOf(address(this));
        // Owed amount = new balance - synced balance (must be >= 0).
        // Subtraction underflow would mean the caller withdrew tokens after
        // sync; that path is not exercised by the M² router.
        paid = nowBal - prev;
        _syncedCurrency = address(0);
        _accountDelta(cur, _unlockedBy, int256(paid));
    }

    /// @notice Mimics `IPoolManager.take`: transfers `amount` of `currency`
    ///         from this contract to `to` and debits the unlocker's delta.
    function take(Currency currency, address to, uint256 amount) external {
        if (_unlockedBy == address(0)) revert ManagerLocked();
        address cur = Currency.unwrap(currency);
        if (cur != address(STABLE) && cur != address(M2_TOKEN)) revert InvalidCurrency();
        _accountDelta(cur, _unlockedBy, -int256(amount));
        IERC20(cur).safeTransfer(to, amount);
    }

    /// @notice Mimics `IPoolManager.swap`: executes a V2-constant-product
    ///         swap against the protocol's full-range position. Folds the
    ///         asymmetric per-direction fee (buy=0.10%, sell=3.00%) into the
    ///         input-currency accumulator (`PhiS` or `PhiT`). Accrues the
    ///         resulting delta to the caller; the caller MUST settle the
    ///         input side via `sync + transfer + settle` and `take` the
    ///         output side before returning from `unlockCallback`.
    /// @dev    Only supports `amountSpecified < 0` (exact-input). The router
    ///         only uses exact-input for buy-and-burn.
    function swap(
        PoolKey memory key,
        SwapParams memory params,
        bytes calldata /* hookData */
    ) external returns (BalanceDelta) {
        if (_unlockedBy == address(0)) revert ManagerLocked();
        if (!initialized) revert NotInitialized();
        if (params.amountSpecified >= 0) revert("MockAMM: exactIn only");

        // Validate the pool key matches our configured pool.
        _validatePoolKey(key);

        uint256 amountIn = uint256(-params.amountSpecified);

        // Determine which currency is being paid in by direction.
        // zeroForOne=true means currency0 is input, currency1 is output.
        bool stableInput;
        if (params.zeroForOne) {
            stableInput = STABLE_IS_CURRENCY0;
        } else {
            stableInput = !STABLE_IS_CURRENCY0;
        }

        uint256 amountOut;
        if (stableInput) {
            amountOut = _swapStableForToken(amountIn);
        } else {
            amountOut = _swapTokenForStable(amountIn);
        }

        // Build the BalanceDelta. The caller is debited the input (negative)
        // and credited the output (positive).
        int128 inDelta = -int128(uint128(amountIn));
        int128 outDelta = int128(uint128(amountOut));

        // Apply delta accounting (input owed, output credited).
        address inCur = stableInput ? address(STABLE) : address(M2_TOKEN);
        address outCur = stableInput ? address(M2_TOKEN) : address(STABLE);
        _accountDelta(inCur, _unlockedBy, int256(inDelta));     // negative
        _accountDelta(outCur, _unlockedBy, int256(outDelta));   // positive

        if (params.zeroForOne) {
            // currency0 = input; currency1 = output
            return toBalanceDelta(inDelta, outDelta);
        } else {
            return toBalanceDelta(outDelta, inDelta);
        }
    }

    /// @notice Mimics `IPoolManager.initialize`. The seed deposits the
    ///         protocol-owned LP reserves. `sqrtPriceX96` is accepted for
    ///         signature parity but ignored; reserves are seeded via
    ///         `seedLiquidity` instead (test-only entry point).
    function initialize(PoolKey memory key, uint160 /* sqrtPriceX96 */)
        external
        view
        returns (int24 tick)
    {
        _validatePoolKey(key);
        // No-op for the mock — `seedLiquidity` performs the actual deposit.
        tick = 0;
    }

    /// @notice Mimics `IPoolManager.modifyLiquidity` with `liquidityDelta == 0`:
    ///         "poke" the position to read fees accrued without changing
    ///         liquidity. For Phase 3 the hook does not call this — fees are
    ///         drained via `drainAccumulators` — but the function is
    ///         implemented for signature completeness and rejects any
    ///         non-zero liquidity delta.
    function modifyLiquidity(
        PoolKey memory key,
        ModifyLiquidityParams memory params,
        bytes calldata /* hookData */
    ) external view returns (BalanceDelta, BalanceDelta) {
        _validatePoolKey(key);
        if (params.liquidityDelta != 0) {
            revert("MockAMM: only poke (liquidityDelta=0) supported");
        }
        // Return zero deltas; the hook reads PhiT/PhiS directly in this phase.
        return (toBalanceDelta(0, 0), toBalanceDelta(0, 0));
    }

    // =================================================================
    // Test-only seed and direct-drain entry points
    // =================================================================

    /// @notice TEST-ONLY: seed the protocol-owned LP with initial reserves.
    ///         Tokens MUST be approved to this contract by the caller. Can be
    ///         called only once; mirrors the Phase 5 genesis-factory step.
    function seedLiquidity(uint256 lt, uint256 ls) external {
        if (initialized) revert AlreadyInitialized();
        if (lt == 0 || ls == 0) revert ZeroLiquidity();
        STABLE.safeTransferFrom(msg.sender, address(this), ls);
        M2_TOKEN.safeTransferFrom(msg.sender, address(this), lt);
        Lt = lt;
        Ls = ls;
        initialized = true;
    }

    /// @notice TEST-ONLY: hook-authorized drain of `(PhiT, PhiS)`. Transfers
    ///         the realized fee amounts to `recipient` (the hook) and resets
    ///         the accumulators to zero. Phase 4 replaces this with V4's
    ///         `modifyLiquidity(0)` + `take(currency)` pattern; the data flow
    ///         (drain to hook, hook distributes) is preserved.
    /// @return tokenRealized The amount of token-side fees realized.
    /// @return stableRealized The amount of stable-side fees realized.
    function drainAccumulators(address recipient)
        external
        returns (uint256 tokenRealized, uint256 stableRealized)
    {
        if (msg.sender != HOOK) revert UnauthorizedHook();
        tokenRealized = PhiT;
        stableRealized = PhiS;
        PhiT = 0;
        PhiS = 0;
        if (tokenRealized > 0) M2_TOKEN.safeTransfer(recipient, tokenRealized);
        if (stableRealized > 0) STABLE.safeTransfer(recipient, stableRealized);
    }

    // =================================================================
    // Test-only LP swap entry points (lpBuy / lpSell)
    // =================================================================
    //
    // The invariant handler exercises external LPBuy / LPSell as separate
    // ops (paper §4.1 Cases 4, 5). Routing them through `unlock + swap` is
    // unnecessary plumbing for Phase 3; the handler calls these helpers
    // directly. Phase 4 will replace them with real `PoolManager.swap`
    // calls inside a periphery `Swap.sol`-like contract.

    /// @notice TEST-ONLY: external user buys M² with `stableIn` stable. The
    ///         caller is debited `stableIn` stable; the protocol-owned LP
    ///         credits `tokensOut` M² to `to`. Same algebra as
    ///         `M2ReferenceModel.lpBuy`.
    function lpBuyExactIn(uint256 stableIn, address to)
        external
        returns (uint256 tokensOut)
    {
        if (!initialized) revert NotInitialized();
        if (stableIn == 0) return 0;
        STABLE.safeTransferFrom(msg.sender, address(this), stableIn);
        tokensOut = _swapStableForToken(stableIn);
        if (tokensOut > 0) M2_TOKEN.safeTransfer(to, tokensOut);
    }

    /// @notice TEST-ONLY: external user sells `tokenIn` M² to the LP. The
    ///         caller is debited `tokenIn` M²; the protocol-owned LP credits
    ///         `stableOut` stable to `to`. Same algebra as
    ///         `M2ReferenceModel.lpSell`.
    function lpSellExactIn(uint256 tokenIn, address to)
        external
        returns (uint256 stableOut)
    {
        if (!initialized) revert NotInitialized();
        if (tokenIn == 0) return 0;
        M2_TOKEN.safeTransferFrom(msg.sender, address(this), tokenIn);
        stableOut = _swapTokenForStable(tokenIn);
        if (stableOut > 0) STABLE.safeTransfer(to, stableOut);
    }

    // =================================================================
    // Internal swap math (mirrors M2ReferenceModel.ts "with-fees")
    // =================================================================

    /// @dev Stable-input swap. Fee fold-in: `feeIn = floor(X * BUY_FEE /
    ///      MAX_LP_FEE)` -> PhiS; `Xnet = X - feeIn` hits the curve.
    ///      Reserves: `LsNew = Ls + Xnet`; `LtNew = k / LsNew` (floor);
    ///      `tokensOut = Lt - LtNew`.
    function _swapStableForToken(uint256 stableIn)
        internal
        returns (uint256 tokensOut)
    {
        uint256 feeIn = (stableIn * uint256(M2Constants.BUY_FEE)) /
            M2Constants.V4_MAX_LP_FEE;
        uint256 xNet = stableIn - feeIn;

        uint256 lt = Lt;
        uint256 ls = Ls;
        if (lt == 0 || ls == 0) revert InsufficientLiquidity();
        uint256 k = lt * ls;
        uint256 lsNew = ls + xNet;
        uint256 ltNew = k / lsNew; // floor — protocol-protective
        tokensOut = lt - ltNew;

        Lt = ltNew;
        Ls = lsNew;
        PhiS += feeIn;
    }

    /// @dev Token-input swap. Fee fold-in: `feeIn = floor(N * SELL_FEE /
    ///      MAX_LP_FEE)` -> PhiT; `Nnet = N - feeIn` hits the curve.
    ///      Reserves: `LtNew = Lt + Nnet`; `LsNew = k / LtNew` (floor);
    ///      `stableOut = Ls - LsNew`.
    function _swapTokenForStable(uint256 tokenIn)
        internal
        returns (uint256 stableOut)
    {
        uint256 feeIn = (tokenIn * uint256(M2Constants.SELL_FEE)) /
            M2Constants.V4_MAX_LP_FEE;
        uint256 nNet = tokenIn - feeIn;

        uint256 lt = Lt;
        uint256 ls = Ls;
        if (lt == 0 || ls == 0) revert InsufficientLiquidity();
        uint256 k = lt * ls;
        uint256 ltNew = lt + nNet;
        uint256 lsNew = k / ltNew; // floor — protocol-protective
        stableOut = ls - lsNew;

        Lt = ltNew;
        Ls = lsNew;
        PhiT += feeIn;
    }

    // =================================================================
    // Internal helpers
    // =================================================================

    function _validatePoolKey(PoolKey memory key) internal view {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool ok;
        if (STABLE_IS_CURRENCY0) {
            ok = (c0 == address(STABLE) && c1 == address(M2_TOKEN));
        } else {
            ok = (c0 == address(M2_TOKEN) && c1 == address(STABLE));
        }
        if (!ok) revert InvalidPool();
    }

    function _accountDelta(address currency, address who, int256 d)
        internal
    {
        if (d == 0) return;
        int256 next = _delta[currency][who] + d;
        _delta[currency][who] = next;
        _hasDelta[currency] = next != 0;
    }

    // =================================================================
    // View helpers
    // =================================================================

    /// @notice Returns the current per-(currency, address) delta accrued in
    ///         the active unlock window. Useful for invariant tests to
    ///         assert net-zero at strategic points.
    function delta(address currency, address who) external view returns (int256) {
        return _delta[currency][who];
    }

    /// @notice Returns `(Lt, Ls, PhiT, PhiS)` in a single call.
    function reserves()
        external
        view
        returns (uint256 lt, uint256 ls, uint256 phiT, uint256 phiS)
    {
        return (Lt, Ls, PhiT, PhiS);
    }
}
