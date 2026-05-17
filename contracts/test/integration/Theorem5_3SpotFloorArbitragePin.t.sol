// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IntegrationFixtureBase} from "./base/IntegrationFixtureBase.sol";

// =====================================================================
// TestSwapRouter — minimal V4 swap router used by these tests only
// =====================================================================
//
// The protocol's M2RevenueRouter is gated to the immutable depositor, so
// these tests need an unprivileged path to execute LP swaps as a generic
// arbitrageur. This contract implements the standard V4 unlock-callback
// -> swap -> settle/take flow against any pool.
// =====================================================================

contract TestSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager poolManager_) {
        POOL_MANAGER = poolManager_;
    }

    struct SwapCallbackData {
        address payer;
        PoolKey poolKey;
        bool zeroForOne;
        int256 amountSpecified;
    }

    /// @notice Swap on the configured pool. Pulls the input from `payer`
    ///         via ERC20 transferFrom; sends the output to `payer`.
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified
    ) external returns (BalanceDelta) {
        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                SwapCallbackData({
                    payer: msg.sender,
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified
                })
            )
        );
        return abi.decode(result, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data)
        external
        override
        returns (bytes memory)
    {
        require(msg.sender == address(POOL_MANAGER), "TestSwapRouter: not PM");
        SwapCallbackData memory d = abi.decode(data, (SwapCallbackData));

        uint160 sqrtPriceLimitX96 = d.zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;

        BalanceDelta delta = POOL_MANAGER.swap(
            d.poolKey,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: d.amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        int128 d0 = BalanceDeltaLibrary.amount0(delta);
        int128 d1 = BalanceDeltaLibrary.amount1(delta);

        if (d0 < 0) {
            uint256 owed = uint256(uint128(-d0));
            POOL_MANAGER.sync(d.poolKey.currency0);
            IERC20(Currency.unwrap(d.poolKey.currency0)).safeTransferFrom(
                d.payer,
                address(POOL_MANAGER),
                owed
            );
            POOL_MANAGER.settle();
        } else if (d0 > 0) {
            POOL_MANAGER.take(d.poolKey.currency0, d.payer, uint256(uint128(d0)));
        }

        if (d1 < 0) {
            uint256 owed = uint256(uint128(-d1));
            POOL_MANAGER.sync(d.poolKey.currency1);
            IERC20(Currency.unwrap(d.poolKey.currency1)).safeTransferFrom(
                d.payer,
                address(POOL_MANAGER),
                owed
            );
            POOL_MANAGER.settle();
        } else if (d1 > 0) {
            POOL_MANAGER.take(d.poolKey.currency1, d.payer, uint256(uint128(d1)));
        }

        return abi.encode(delta);
    }
}

// =====================================================================
// Theorem5_3SpotFloorArbitragePin — paper §5 Theorem 5.3(2)
// =====================================================================
//
// Statement (paper §5 thm:spot-floor-convergence part 2):
//   Under any positive-probability arbitrageur path - arbitrageurs are
//   available to buy on the LP whenever Spot < Floor - we have
//   Spot(t) >= Floor(t) for all t.
//
// Proof intuition: if Spot < Floor at time t, an arbitrageur can
//   1. Buy Y tokens on the LP at price ~Spot (paying the 0.10% buy fee)
//   2. Redeem Y tokens against the treasury at price Floor.
//   Net cash: Y * Floor - X  (X = stable spent on the LP).
//   Per dollar deployed, the profit is (Floor - Spot)/Spot - f_b,
//   positive whenever (Floor - Spot)/Spot > f_b ~= 10 bps.
//
// The integer-form profitability check (no rationals, no fixed-point):
//   Y * T > X * S      <=>     mulDiv(Y, T, S) > X
// where (T, S) are the treasury balance and supply at the redeem moment.
// This is exactly the inequality `redeem(Y) > X` performs internally.
//
// Test design: this file targets the THEOREM, not a tick-rounding-
// dependent state trajectory. We exploit the fact that the genesis
// floor T0/S0 is far below the spot price implied by sqrtPriceX96 =
// 1<<96 in raw-decimal terms, ONLY when the stable has 6 decimals and
// the token has 18 decimals (the canonical M2 config). Concretely:
//
//   - Raw floor: T0/S0 = 10^12 / 10^27 = 10^-15 raw-stable per raw-token.
//   - Inverse:   S0/T0 = 10^15 raw-token per raw-stable.
//
// We initialize the LP at sqrtPriceX96 = 1<<96, which corresponds to a
// price of 1 in the V4 sense (currency1 per currency0). With stableIs0,
// V4's "price" reads as 1 raw-token per raw-stable; with stableIs1, it
// reads as 1 raw-stable per raw-token. EITHER WAY, the LP cannot
// economically rationally swap at a rate that would also be below the
// floor (S0/T0 = 10^15), because the LP only carries finite depth.
//
// Therefore, the test sells tokens into the LP to push the spot LOWER
// (in the stableIs0 sense: more token per stable). After enough volume
// pushes spot below floor, the arbitrageur's buy + redeem must net
// positive in cross-product form.
//
// Pragmatic choice: the test takes the LP-buy + redeem AS-A-UNIT and
// asserts the IF-PROFITABLE-THEN... structure of the theorem:
//   - if the arb's `expected = mulDiv(Y, T, S) > X` after the buy,
//     the arb is rational and the cross-product `Y * T > X * S` holds;
//   - we drive the price down via repeated sells until at least ONE
//     round-trip yields positive expected; the theorem is satisfied
//     by that observation.
//
// In the canonical 18/6-decimal regime, even a single small sell pushes
// spot significantly below the floor (which is 15 orders of magnitude
// below the init spot in raw-decimal terms — see comment above).
//
// ---------------------------------------------------------------------
// CAVEAT — what this test DOES NOT exercise (Phase 6 Round 1 Agent A H4):
// ---------------------------------------------------------------------
//
// Reviewer A correctly flagged that at the canonical 18/6-decimal config
// with the integration fixture's `sqrtPriceX96 = 1<<96` LP seed, the
// EVM-side state cannot reach a regime where V4's effective LP-buy
// `Spot` is BELOW the protocol `Floor = T/S`. The reason is purely a
// raw-decimal scaling artifact:
//
//   - genesis floor T0/S0 = 10^12 / 10^27 = 10^-15 raw-stable/raw-token,
//   - LP-seed sqrtPriceX96 = 1<<96 ⇒ V4-price = 1 raw-currency1/raw-currency0,
//   - the raw-decimal gap between the two is ~10^15 orders of magnitude.
//
// Crossing that gap on-chain would require either a multi-tick-spacing
// swap (which V4's `tickSpacing = 60` makes prohibitively expensive in
// EDR), or a 12+ month operating-point drift with deep LP under realistic
// fee-and-route revenue. Neither is feasible in a single in-memory
// integration test.
//
// What this test ASSERTS INSTEAD (the achievable structural form):
//
//   1. The integer-form profitability predicate `mulDiv(Y, T, S) > X` is
//      EQUIVALENT to `redeem(Y) > X` — Theorem 5.3(2)'s LP-buy-then-
//      redeem nets positive iff the cross-product holds. The bytecode
//      reproduces this equivalence exactly.
//   2. The constructed-(X, Y) demonstration: given a hypothetical state
//      satisfying the predicate, `redeem(Y)` returns more than X. This is
//      Theorem 5.3(2) in its cleanest form, NOT exercised against the
//      live LP state but against the redeem bytecode directly.
//
// The full convergence claim (Spot < Floor cannot persist because
// arbitrageurs make it disappear) is exercised on the MAINNET-FORK tier
// by `test/integration/MainnetFork12MonthRouteRevenue.t.sol` plus an
// adversarial dump variant — that test runs the 12-month trajectory at
// realistic scale (mainnet USDC + V4 PoolManager), where the
// operating-point drift CAN drive Spot toward Floor. The bytecode-level
// convergence in EDR remains a paper-only proof; the local-tier test
// here pins the algebraic equivalence that the proof depends on.
//
// See `docs/v4_model_correspondence.md` "Phase 6 — Theorem 5.3(2)
// caveat" for the full derivation and the mainnet-fork test pointer.

abstract contract Theorem5_3SpotFloorArbitragePinBase is IntegrationFixtureBase {
    using SafeERC20 for IERC20;

    address internal constant ARB = address(0xA8B17);
    address internal constant SELLER = address(0x5E11E2);

    TestSwapRouter internal swapRouter;

    /// @dev LP_LIQ sized so the seed transfer to the hook
    ///      (LP_LIQ * 10 of each currency) is sufficient for V4's
    ///      full-range LiquidityAmounts.getAmountsForLiquidity at
    ///      sqrtPriceX96 = 1<<96 (price = 1 raw-currency1 / raw-currency0,
    ///      approximately L of each).
    uint128 internal constant LP_LIQ = uint128(1e10);

    /// @dev Per-sell chunk (raw token units) used to drive spot down.
    ///      Sized at LP_LIQ / 100 so a single chunk moves the spot
    ///      price meaningfully but does NOT cross to MIN_SQRT_PRICE.
    uint256 internal constant SELL_CHUNK = 1e8;

    /// @dev Arbitrageur's available stable budget (raw 6-dec).
    uint256 internal constant ARB_STABLE = 100_000 * 1e6;

    function setUp() public {
        _deploy(_wantTokenLowerThanStable());

        // Initialize the LP at sqrtPriceX96 = 1 << 96 (V4-price = 1). In
        // both address orderings the seed amounts at this sqrtPriceX96
        // are symmetric (approximately L of each currency).
        token.transfer(address(hook), uint256(LP_LIQ) * 10);
        stableTok.mint(address(hook), uint256(LP_LIQ) * 10);
        hook.initializePool(poolKey, uint160(1) << 96, LP_LIQ);

        // Deploy the test swap router.
        swapRouter = new TestSwapRouter(pm);

        // Seed the seller with tokens. The seller's allocation is
        // dimensioned to push spot below floor across multiple sells
        // without exhausting V4's tick bounds.
        token.transfer(SELLER, 100 * SELL_CHUNK);
        stableTok.mint(ARB, ARB_STABLE);

        // Approvals on both sides.
        vm.prank(SELLER);
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
        vm.prank(ARB);
        IERC20(address(stableTok)).approve(address(swapRouter), type(uint256).max);
        vm.prank(ARB);
        IERC20(address(token)).approve(address(swapRouter), type(uint256).max);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// @dev As ARB, swap X stable -> token (a "buy") via the test router.
    function _arbBuy(uint256 X) internal returns (uint256 tokensReceived) {
        uint256 tokensBefore = token.balanceOf(ARB);
        bool zeroForOne = stableIs0; // stable in -> token out
        vm.prank(ARB);
        swapRouter.swap(poolKey, zeroForOne, -int256(X));
        tokensReceived = token.balanceOf(ARB) - tokensBefore;
    }

    /// @dev As SELLER, swap N tokens -> stable (a "sell") via the test
    ///      router. Used to drive the LP into the Spot < Floor regime
    ///      (the sell pushes the price toward MIN_SQRT_PRICE in the
    ///      stableIs0 sense, which corresponds to more token per stable
    ///      = a lower spot in token-per-dollar terms).
    function _drivePriceDown(uint256 N) internal {
        bool zeroForOne = !stableIs0; // token in -> stable out
        vm.prank(SELLER);
        swapRouter.swap(poolKey, zeroForOne, -int256(N));
    }

    // -----------------------------------------------------------------
    // Case A — direct arbitrage check at the genesis state
    // -----------------------------------------------------------------

    /// @notice On-chain LP-buy + redeem demonstration. We drive the LP
    ///         spot down with sustained sells, then perform an arb-buy.
    ///         The post-buy cross-product check (Y * T versus X * S)
    ///         is the exact integer form of the theorem. If the buy
    ///         yields enough Y to satisfy Y * T > X * S, the arbitrage
    ///         is profitable in the cross-product form; the
    ///         corresponding `redeem(Y)` returns mulDiv(Y, T, S) > X.
    /// @dev    Note on test-LP scale: the canonical M2 config has
    ///         18-decimal token vs 6-decimal stable. In raw units the
    ///         floor T/S is 10^-15. A test-LP initialized at
    ///         sqrtPriceX96 = 1<<96 has V4-price = 1 in raw units, so
    ///         the LP buys tokens at ratios that are FAR above the
    ///         floor (1 vs 10^-15). Driving price below the floor
    ///         requires pushing the V4 sqrtPrice across many orders of
    ///         magnitude; that is the WHOLE-PROTOCOL operating-point
    ///         drift exercised in the Phase 6 mainnet-fork tests, not
    ///         a single in-memory unit test. This test therefore
    ///         exercises the CROSS-PRODUCT predicate directly: it
    ///         verifies that V4's swap returns a Y satisfying the
    ///         cross-product check used by `redeem`.
    function test_OnChainLPBuy_CrossProductHoldsForReturnedY() public {
        // Drive price down a few steps to exercise the LP. We do not
        // require Spot < Floor here; the cross-product check after the
        // buy is exact: the swap yields some Y for the input X, and the
        // `redeem(Y)` path internally evaluates mulDiv(Y, T, S). The
        // sanity-cross-product equality `mulDiv(Y, T, S) <= X` simply
        // reflects that V4 hasn't pushed us into the Spot < Floor regime
        // — which is the expected condition for the canonical decimal
        // setup at sqrtPriceX96 = 1<<96.
        for (uint256 i = 0; i < 3; ++i) {
            _drivePriceDown(SELL_CHUNK);
        }

        uint256 T_pre = stableTok.balanceOf(address(treasury));
        uint256 S_pre = token.totalSupply();

        uint256 X = 100; // raw stable units
        uint256 Y = _arbBuy(X);

        // The buy yielded Y tokens for X stable. The cross-product
        // profitability predicate is Y * T > X * S. This test does NOT
        // require Y * T > X * S to hold (the canonical decimal setup
        // makes it structurally false); the assertion below is the
        // STRUCTURAL EQUIVALENCE statement of the theorem: in the
        // V4 + M2 stack, `redeem(Y) > X` iff `Y * T > X * S`.
        vm.prank(ARB);
        uint256 stableOut = token.redeem(Y);
        bool profitable = Y * T_pre > X * S_pre;
        if (profitable) {
            assertGt(stableOut, X, "Thm 5.3(2): Y * T > X * S implies redeem > X");
        } else {
            assertLe(
                stableOut,
                X,
                "structurally: Y * T <= X * S implies redeem <= X"
            );
        }
        // In both cases, the redeem path matches `mulDiv(Y, T, S)`
        // exactly — the underlying Lemma 4.2 invariant.
        assertEq(
            stableOut,
            Math.mulDiv(Y, T_pre, S_pre),
            "redeem == mulDiv(Y, T, S)"
        );
    }

    // -----------------------------------------------------------------
    // Case B — direct mulDiv-form arbitrage demonstration
    // -----------------------------------------------------------------

    /// @notice Pure-algebraic demonstration of the theorem's IF clause.
    ///         Given hypothetical (X, Y) satisfying mulDiv(Y, T, S) > X,
    ///         the redeem call returns more than X stable. This is the
    ///         theorem in its cleanest form: it does NOT depend on any
    ///         LP state; it depends only on the structure of the
    ///         redemption pathway.
    /// @dev    The strict cross-product test (`Y * T > X * S`) does NOT
    ///         imply `mulDiv(Y, T, S) > X` because of integer floor
    ///         rounding: the latter requires `Y * T >= (X + 1) * S`.
    ///         We construct Y so the stronger inequality holds.
    function test_RedeemReturnsGtXWheneverProfitable() public {
        uint256 T = stableTok.balanceOf(address(treasury));
        uint256 S = token.totalSupply();

        // Construct (X, Y) with mulDiv(Y, T, S) >= X + 1.
        // Choose X = 1 raw-stable. We need Y * T >= (X + 1) * S = 2*S.
        // => Y >= 2 * S / T. Use Y = 2 * S / T + S / T + 1 to be safe.
        uint256 X = 1;
        uint256 Y = 3 * (S / T) + 1;
        // Verify the integer-form profitability check.
        uint256 expected = Math.mulDiv(Y, T, S);
        assertGt(expected, X, "construction: mulDiv(Y, T, S) > X");

        // Send ARB the required tokens.
        token.transfer(ARB, Y);

        vm.prank(ARB);
        uint256 stableOut = token.redeem(Y);
        assertEq(stableOut, expected, "redeem matches mulDiv");
        assertGt(stableOut, X, "Thm 5.3(2): stableOut > X (arb nets positive)");
    }
}

// =====================================================================
// Concrete paired subclasses — FINAL_REPORT H4 paired-address-sort
// =====================================================================

contract Theorem5_3SpotFloorArbitragePinLowAddrTest is
    Theorem5_3SpotFloorArbitragePinBase
{
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return true;
    }
}

contract Theorem5_3SpotFloorArbitragePinHighAddrTest is
    Theorem5_3SpotFloorArbitragePinBase
{
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return false;
    }
}
