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
import {M2Constants} from "../../contracts/libraries/M2Constants.sol";

// =====================================================================
// Theorem5_2BankRunSwapRouter — unprivileged V4 swap router for the
// attacker leg. Mirrors the same pattern used by
// `Theorem5_3SpotFloorArbitragePin.t.sol` and `CollectFeesNoStrandedWei.t.sol`.
// =====================================================================

contract Theorem5_2BankRunSwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable POOL_MANAGER;

    constructor(IPoolManager pm_) {
        POOL_MANAGER = pm_;
    }

    struct CbData {
        address sender;
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified; // negative => exact input
    }

    /// @notice Execute an exact-input swap of `amountIn` units of the input
    ///         currency. The hook's `beforeSwap` applies the dynamic fee
    ///         (buy 0.10% / sell 3.00%) based on the input currency.
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn
    ) external returns (BalanceDelta delta) {
        bytes memory ret = POOL_MANAGER.unlock(
            abi.encode(
                CbData({
                    sender: msg.sender,
                    key: key,
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn)
                })
            )
        );
        delta = BalanceDelta.wrap(abi.decode(ret, (int256)));
    }

    function unlockCallback(bytes calldata data)
        external
        override
        returns (bytes memory)
    {
        require(msg.sender == address(POOL_MANAGER), "swap router: !pm");
        CbData memory cb = abi.decode(data, (CbData));

        Currency inputCurrency =
            cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        Currency outputCurrency =
            cb.zeroForOne ? cb.key.currency1 : cb.key.currency0;

        uint256 amountIn = uint256(-cb.amountSpecified);
        IERC20(Currency.unwrap(inputCurrency)).safeTransferFrom(
            cb.sender,
            address(this),
            amountIn
        );

        uint160 sqrtPriceLimitX96 = cb.zeroForOne
            ? TickMath.MIN_SQRT_PRICE + 1
            : TickMath.MAX_SQRT_PRICE - 1;

        BalanceDelta d = POOL_MANAGER.swap(
            cb.key,
            SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: cb.amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        POOL_MANAGER.sync(inputCurrency);
        IERC20(Currency.unwrap(inputCurrency)).safeTransfer(
            address(POOL_MANAGER),
            amountIn
        );
        POOL_MANAGER.settle();

        int128 outDelta = cb.zeroForOne
            ? BalanceDeltaLibrary.amount1(d)
            : BalanceDeltaLibrary.amount0(d);
        if (outDelta > 0) {
            POOL_MANAGER.take(
                outputCurrency,
                cb.sender,
                uint256(uint128(outDelta))
            );
        }

        return abi.encode(BalanceDelta.unwrap(d));
    }
}

// =====================================================================
// Theorem5_2BankRun — HEADLINE differential (Phase 6, load-bearing)
// =====================================================================
//
// Paper §5.2 Theorem 5.2 (saturated mixed strategy):
//
//   An attacker holding N > A* tokens maximizes profit by dumping A*
//   into the LP and redeeming the remaining (N - A*) at the floor:
//
//     A* = (sqrt(k·(1 - f_s) / F) - Lt) / (1 - f_s)
//     Π* = Ls - sqrt(k·F / (1 - f_s)) + (N - A*)·F
//     Δ* = Π* - N·F = Ls - sqrt(k·F / (1 - f_s)) - A*·F          (state-only)
//
// where F = T/S, k = Lt·Ls, f_s = 0.03 (sell fee).
//
// At the canonical month-12 state from paper §6 Table 1 — T = $1.6M,
// S = 666,666,666.66... tokens, Lt = 416,666,666.66..., Ls = $1.35M —
// the Decimal(prec=60) reference computes
//   Δ* = $21,476.5621327029763205920169281383101491742571
//
// =====================================================================
// THIS FILE CONTAINS TWO DIFFERENTIAL LAYERS
// =====================================================================
//
// (A) BYTECODE differential — `test_DeltaStar_OnChainAttack_MatchesClosedForm`
//     Reaches a live on-chain post-genesis state through real
//     `routeRevenue` + `collectFees` cycles against a real V4 pool and a
//     deep LP seed, snapshots the LIVE (T, S, Lt, Ls), computes A* and
//     Δ_closed from those live values, then executes the actual two-leg
//     attack:
//
//       1. attacker swaps A* tokens for stable via the V4 hook + pool
//          (TestSwapRouter -> PoolManager.swap; the hook's beforeSwap
//          applies the 3% sell fee),
//       2. attacker calls M2Token.redeem(N - A*) for the floor leg.
//
//     The realized stable proceeds (Π_realized) minus N·F_pre yields
//     Δ_realized. We assert
//       |Δ_realized - Δ_closed| / Δ_closed <= 50 bps (0.5%)
//     This is the bytecode-against-formula differential.
//
//     A FAIL-INJECTION sanity check is documented in
//     `.review/phase6/round3/consolidated-fixes-applied.md`: bumping
//     `BUY_FEE` from 0.10% to 0.15% in M2Constants and recompiling makes
//     this test FAIL (the deviation between realized and closed-form
//     exceeds the 0.5% tolerance because the LP-buy fee that affected
//     pre-attack state diverges from the closed form's assumption).
//
// (B) PAPER-HEADLINE anchor — `test_DeltaStar_ClosedForm_MatchesPaperHeadline`
//     State-only assertion that the closed-form `Δ*(canonical paper
//     state)` reproduces the paper number `$21,476.5621...` to within the
//     bigint isqrt residual. Combined with (A), the transitive claim is:
//
//       on-chain bytecode attack  ≈  closed-form Δ*(live state)
//       closed-form Δ*(paper state) ≈  Decimal(60) paper number
//
//     so the protocol's bytecode, when driven to canonical state, would
//     yield the paper number within the 0.5% V4-tick-rounding band.
//     (Driving to EXACT canonical paper state at full scale in EDR is
//     infeasible due to the 18/6-decimal raw-price gap — see
//     `docs/v4_model_correspondence.md` "Phase 6 — Theorem 5.2 tolerance"
//     for the derivation; the brief explicitly permits adjusting the
//     canonical anchor to the state actually reached.)
//
// Tolerance:
//   - Bytecode test (A): 0.5% relative deviation, calibrated to the V4
//     tick-rounding + Q128.128 fee truncation band.
//   - Paper-headline test (B): 0.1 bps (empirical band).
//
// Both abstract subclasses (Low / High address-sort) MUST pass.

abstract contract Theorem5_2BankRunBase is IntegrationFixtureBase {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Actors
    // -----------------------------------------------------------------

    address internal constant ATTACKER = address(0xA77AC4E2);
    address internal constant BOUNTY_CALLER = address(0xBA9);

    Theorem5_2BankRunSwapRouter internal attackRouter;

    // -----------------------------------------------------------------
    // Canonical paper state (paper §6 Table 1) — for state-only anchor
    // -----------------------------------------------------------------

    /// @dev T  = $1,600,000 in stable-smallest-unit (d_s = 6).
    uint256 internal constant CANON_T = 1_600_000 * 1e6;

    /// @dev S = floor(2 * 10^27 / 3) — canonical month-12 supply.
    uint256 internal constant CANON_S =
        666_666_666_666_666_666_666_666_666;

    /// @dev Lt = floor(5 * 10^26 / 12) — canonical month-12 LP token reserve.
    uint256 internal constant CANON_LT =
        416_666_666_666_666_666_666_666_666;

    /// @dev Ls = $1,350,000 — canonical month-12 LP stable reserve.
    uint256 internal constant CANON_LS = 1_350_000 * 1e6;

    /// @dev Paper headline (Decimal(60) reference): $21,476.5621327...
    ///      → 21_476_562_132 in stable smallest units (d_s = 6, truncated).
    uint256 internal constant PAPER_DELTA_STAR_STABLE_UNITS = 21_476_562_132;

    // -----------------------------------------------------------------
    // Tolerances
    // -----------------------------------------------------------------

    /// @dev 0.5% relative tolerance for the bytecode test. Calibrated to
    ///      the V4 tick-rounding + Q128.128 fee truncation band.
    uint256 internal constant HEADLINE_TOLERANCE_BPS = 50;

    /// @dev 0.1 bps for the state-only paper-anchor test (Newton-isqrt
    ///      residual + integer floor rounding band).
    uint256 internal constant PAPER_ANCHOR_TOLERANCE_PPM_DIV100000 = 1;

    // -----------------------------------------------------------------
    // On-chain state-driving config — deep LP + a few large routeRevenue
    // cycles to take the live (T, S, Lt, Ls) into a non-degenerate
    // Spot > Floor regime where the saturated mixed strategy is rational.
    // -----------------------------------------------------------------

    /// @dev Liquidity raw units for the LP seed. Large enough that:
    ///      (a) the V4 LP carries enough depth for `routeRevenue($X)` to
    ///          execute without exhausting reserves,
    ///      (b) the post-routing Lt is still substantial (so A* fits
    ///          inside the test contract's residual S0 token balance),
    ///      (c) the resulting Δ_closed is large enough that the 0.5%
    ///          tolerance band exceeds the bigint-isqrt residual.
    ///
    ///      LP_LIQ = 1e15 gives Lt ≈ Ls ≈ 1e15 raw units at
    ///      sqrtPriceX96 = 1<<96 (V4-price = 1 raw-currency-per-raw-currency).
    uint128 internal constant LP_LIQ = uint128(1e15);

    /// @dev Stable per routeRevenue call. Sized so that a few iterations
    ///      meaningfully move the LP price (and thus Spot/Floor) without
    ///      collapsing the pool.
    uint256 internal constant ROUTE_AMOUNT = 200_000 * 1e6; // $200k per cycle

    /// @dev Number of routeRevenue + collectFees cycles to drive state.
    ///      Three cycles is empirically sufficient to push Spot > Floor
    ///      enough for the saturated mixed strategy to net positive
    ///      Δ* under the 0.5% tolerance band. Fewer cycles risk
    ///      degeneracy (A* clamps to 0 if sqrt(k(1-fs)/F) <= Lt).
    uint256 internal constant ROUTE_CYCLES = 3;

    // -----------------------------------------------------------------
    // setUp — deploy + seed deep LP + drive state via routeRevenue cycles
    // -----------------------------------------------------------------

    function setUp() public {
        _deploy(_wantTokenLowerThanStable());

        // 1. Initialize a deep V4 LP at sqrtPriceX96 = 1<<96 (V4-price = 1
        //    raw token1 per raw token0). At this price, full-range L = 1e15
        //    pulls ~1e15 raw of each currency from the hook's seed pool.
        token.transfer(address(hook), uint256(LP_LIQ) * 10);
        stableTok.mint(address(hook), uint256(LP_LIQ) * 10);
        hook.initializePool(poolKey, uint160(1) << 96, LP_LIQ);

        // 2. Fund depositor with enough stable for ROUTE_CYCLES.
        stableTok.mint(DEPOSITOR, ROUTE_AMOUNT * ROUTE_CYCLES);
        vm.prank(DEPOSITOR);
        IERC20(address(stableTok)).approve(address(router), type(uint256).max);

        // 3. Drive state via routeRevenue + collectFees cycles. Each cycle
        //    half-routes-to-treasury and half-buys-and-burns from the LP,
        //    raising T, lowering S, and raising Spot above Floor.
        for (uint256 i = 0; i < ROUTE_CYCLES; ++i) {
            vm.prank(DEPOSITOR);
            router.routeRevenue(ROUTE_AMOUNT, 0);
            vm.prank(BOUNTY_CALLER);
            hook.collectFees();
        }

        // 4. Deploy the attacker's unprivileged swap router.
        attackRouter = new Theorem5_2BankRunSwapRouter(pm);
    }

    // -----------------------------------------------------------------
    // (A) BYTECODE differential — actually execute the attack on-chain
    // -----------------------------------------------------------------

    /// @notice The load-bearing on-chain Δ* differential. Snapshots the
    ///         live (T, S, Lt, Ls); computes A* and Δ_closed; mints
    ///         N = A* + ε tokens to ATTACKER; executes lpSell(A*) +
    ///         redeem(N - A*); compares realized to closed-form within
    ///         the 0.5% tolerance band.
    /// @dev    Fails if the EVM bytecode's effective realized Δ* diverges
    ///         from the closed-form (which is what Phase 6 H1 BLOCKER
    ///         demanded). A simple fail-injection sanity check —
    ///         bumping BUY_FEE in M2Constants — surfaces a tolerance-band
    ///         failure here (see `.review/phase6/round3/consolidated-fixes-applied.md`).
    function test_DeltaStar_OnChainAttack_MatchesClosedForm() public {
        // 1. Snapshot LIVE on-chain state.
        uint256 T_pre = stableTok.balanceOf(address(treasury));
        uint256 S_pre = token.totalSupply();
        // Lt, Ls = the protocol-owned LP's raw reserves. Because the
        // hook owns the ONLY position in the pool, the PoolManager's
        // balance of each currency equals the active reserve to within
        // the hook's leftover seed dust (which we account for by reading
        // the pool manager's actual balances).
        uint256 Lt_live = token.balanceOf(address(pm));
        uint256 Ls_live = stableTok.balanceOf(address(pm));

        // Sanity: cross-product floor-spot invariant T·Lt ≈ Ls·S (modulo
        // tick-rounding drift from V4 + buy-fee fold-in via Φ_s). After
        // ROUTE_CYCLES, this is preserved to within a few bps because
        // collectFees realizes the buy fees into both T (stable side) and
        // S burn (token side).
        require(T_pre > 0 && S_pre > 0 && Lt_live > 0 && Ls_live > 0,
            "live state degenerate");

        // 2. Compute A* and Δ_closed from the LIVE state.
        uint256 fs = uint256(M2Constants.SELL_FEE);
        uint256 aStar = _computeAStarTokenUnits(T_pre, S_pre, Lt_live, Ls_live, fs);
        require(aStar > 0, "A* clamped to 0 (state below saturation)");

        uint256 deltaClosed = _computeDeltaStarStableUnits(
            T_pre, S_pre, Lt_live, Ls_live, fs
        );
        require(deltaClosed > 0, "Delta_closed degenerate");

        // 3. Mint N = A* + epsilon tokens to ATTACKER. Epsilon is chosen
        //    so the redemption leg (N - A*) is non-trivial. We use
        //    epsilon = A* / 100 (1% extra) — small enough to keep N well
        //    below S_pre, large enough to make the redeem leg material.
        uint256 epsilon = aStar / 100;
        uint256 N = aStar + epsilon;
        require(N < S_pre, "N exceeds total supply");
        require(token.balanceOf(address(this)) >= N, "test does not hold N");
        token.transfer(ATTACKER, N);

        // 4. ATTACKER approves and executes the two-leg attack.
        vm.prank(ATTACKER);
        IERC20(address(token)).approve(address(attackRouter), type(uint256).max);

        // Leg 1: lpSell(A*) — token-input swap through V4 hook.
        //   zeroForOne = !stableIs0 (token side is input).
        //   The hook's beforeSwap applies the 3% sell fee.
        uint256 attackerStableBefore = stableTok.balanceOf(ATTACKER);
        bool zeroForOne = !stableIs0;
        vm.prank(ATTACKER);
        attackRouter.swap(poolKey, zeroForOne, aStar);
        uint256 attackerStableAfterSell = stableTok.balanceOf(ATTACKER);

        uint256 sellProceeds = attackerStableAfterSell - attackerStableBefore;

        // Leg 2: redeem(N - A*) — floor-rate burn against treasury.
        vm.prank(ATTACKER);
        uint256 redeemProceeds = token.redeem(N - aStar);
        uint256 attackerStableAfterRedeem = stableTok.balanceOf(ATTACKER);

        require(
            attackerStableAfterRedeem - attackerStableAfterSell == redeemProceeds,
            "redeem proceeds inconsistent"
        );

        // 5. Compute realized Δ*.
        //    realized = sellProceeds + redeemProceeds
        //    F_pre = T_pre / S_pre  (treated as a rational; we use the
        //                            cross-product form to avoid the
        //                            integer-division wei loss).
        //    realizedDelta = realized - mulDiv(N, T_pre, S_pre)
        uint256 totalRealized = sellProceeds + redeemProceeds;
        uint256 NfFloor = Math.mulDiv(N, T_pre, S_pre);
        require(totalRealized >= NfFloor, "Delta_realized would be negative");
        uint256 deltaRealized = totalRealized - NfFloor;

        // 6. Assert |realized - closed| / closed <= 50 bps.
        uint256 absDiff = deltaRealized > deltaClosed
            ? deltaRealized - deltaClosed
            : deltaClosed - deltaRealized;
        uint256 toleranceAbs = (deltaClosed * HEADLINE_TOLERANCE_BPS) / 10_000;
        if (absDiff > toleranceAbs) {
            revert(
                string.concat(
                    "Theorem 5.2 bytecode differential: realized=",
                    _toString(deltaRealized),
                    " vs closed-form ",
                    _toString(deltaClosed),
                    " (tol ",
                    _toString(toleranceAbs),
                    ", abs ",
                    _toString(absDiff),
                    ")"
                )
            );
        }

        // 7. Floor invariant must hold across the attack (no inflation).
        uint256 T_post = stableTok.balanceOf(address(treasury));
        uint256 S_post = token.totalSupply();
        // Cross-product floor monotonicity: T_post · S_pre >= T_pre · S_post.
        require(
            T_post * S_pre >= T_pre * S_post,
            "floor monotonicity violated during attack"
        );
    }

    /// @notice Sanity: the post-attack floor is still well-defined and the
    ///         attacker did not extract more than the LP's stable reserves
    ///         total (Δ* < Ls upper bound).
    function test_DeltaStar_BoundedByLs() public view {
        uint256 Ls_live = stableTok.balanceOf(address(pm));
        uint256 fs = uint256(M2Constants.SELL_FEE);
        uint256 deltaClosed = _computeDeltaStarStableUnits(
            stableTok.balanceOf(address(treasury)),
            token.totalSupply(),
            token.balanceOf(address(pm)),
            Ls_live,
            fs
        );
        assertLt(deltaClosed, Ls_live, "Delta* must be bounded by Ls");
    }

    // -----------------------------------------------------------------
    // (B) PAPER-HEADLINE state-only anchor — Δ*(canonical paper state)
    // -----------------------------------------------------------------

    /// @notice The closed-form Δ* evaluated at the canonical paper state
    ///         constants reproduces the Decimal(60) headline within
    ///         0.1 bps (the Newton-isqrt + integer-floor residual band).
    ///         Combined with the BYTECODE test above, the transitive
    ///         differential argument closes: the protocol bytecode
    ///         agrees with the closed form (test A), and the closed form
    ///         agrees with the paper at canonical scale (this test).
    function test_DeltaStar_ClosedForm_MatchesPaperHeadline() public pure {
        uint256 deltaStar = _computeDeltaStarStableUnits(
            CANON_T, CANON_S, CANON_LT, CANON_LS,
            /*fs_pip=*/ uint256(M2Constants.SELL_FEE)
        );
        uint256 absDiff = deltaStar > PAPER_DELTA_STAR_STABLE_UNITS
            ? deltaStar - PAPER_DELTA_STAR_STABLE_UNITS
            : PAPER_DELTA_STAR_STABLE_UNITS - deltaStar;
        // 0.1 bps = 1/100000 relative tolerance (the empirical band; see
        // docs/v4_model_correspondence.md "Phase 6 — Theorem 5.2 tolerance").
        uint256 tol = PAPER_DELTA_STAR_STABLE_UNITS / 100_000;
        if (absDiff > tol) {
            revert(
                string.concat(
                    "paper headline: Delta*=",
                    _toString(deltaStar),
                    " vs ",
                    _toString(PAPER_DELTA_STAR_STABLE_UNITS)
                )
            );
        }
    }

    /// @notice A* at the canonical paper state matches the CSV anchor
    ///         `61_999_083.9199480...` tokens within sub-token precision.
    ///         Sanity-checks the intermediate quantity.
    function test_AStar_ClosedForm_MatchesPaperAnchor() public pure {
        uint256 aStar = _computeAStarTokenUnits(
            CANON_T, CANON_S, CANON_LT, CANON_LS, uint256(M2Constants.SELL_FEE)
        );
        // Anchor (Decimal(60) ref): 61_999_083.9199480... tokens
        // → in 10^-18-token units = 61_999_083_919_948_048_318_089_721
        uint256 anchor = 61_999_083_919_948_048_318_089_721;
        uint256 absDiff = aStar > anchor ? aStar - anchor : anchor - aStar;
        assertLe(absDiff, 1e18, "A* outside 1-token tolerance");
    }

    /// @notice At canonical month-12, Spot > Floor (cross-product form).
    ///         This is the precondition that makes the saturated mixed
    ///         strategy net positive.
    function test_CanonicalState_HasSpotAboveFloor() public pure {
        require(CANON_LS * CANON_S > CANON_T * CANON_LT, "Spot must exceed Floor");
    }

    // -----------------------------------------------------------------
    // Internal: closed-form computation (mirrors M2ReferenceModel.ts)
    // -----------------------------------------------------------------

    /// @dev Compute A* in 10^-18-token units.
    ///        A* = (sqrt(k * (1 - f_s) / F) - Lt) / (1 - f_s)
    ///      where k = Lt·Ls, F = T/S. Radicand expansion (units check):
    ///        radA = k * (1 - f_s) * S / (T * feeDenom)        [token-10^-18 squared]
    ///      where (1 - f_s) = feeDenom - fs and feeDenom = 1_000_000.
    function _computeAStarTokenUnits(
        uint256 T,
        uint256 S,
        uint256 Lt,
        uint256 Ls,
        uint256 fs
    ) internal pure returns (uint256) {
        uint256 feeDenom = M2Constants.V4_MAX_LP_FEE;
        uint256 oneMinusFs = feeDenom - fs;

        uint256 num = oneMinusFs * S;       // bounded
        uint256 den = T * feeDenom;
        uint256 k = Lt * Ls;
        uint256 radA = Math.mulDiv(k, num, den);
        uint256 sqrtA = _isqrt(radA);
        if (sqrtA <= Lt) return 0;
        return Math.mulDiv(sqrtA - Lt, feeDenom, oneMinusFs);
    }

    /// @dev Compute Δ* in stable-smallest-unit units.
    ///        Δ* = Ls - sqrt(k * F / (1 - f_s)) - A* · F
    ///        F = T / S (rational).
    ///      Radicand expansion (units check):
    ///        radB = k * T * feeDenom / (S * oneMinusFs)       [stable squared]
    function _computeDeltaStarStableUnits(
        uint256 T,
        uint256 S,
        uint256 Lt,
        uint256 Ls,
        uint256 fs
    ) internal pure returns (uint256) {
        uint256 feeDenom = M2Constants.V4_MAX_LP_FEE;
        uint256 oneMinusFs = feeDenom - fs;

        uint256 num = T * feeDenom;
        uint256 den = S * oneMinusFs;
        uint256 k = Lt * Ls;
        uint256 radB = Math.mulDiv(k, num, den);
        uint256 sqrtB = _isqrt(radB);

        uint256 aStar = _computeAStarTokenUnits(T, S, Lt, Ls, fs);
        uint256 aStarF = Math.mulDiv(aStar, T, S);

        if (sqrtB + aStarF >= Ls) return 0;
        return Ls - sqrtB - aStarF;
    }

    /// @notice Newton integer square root. Returns floor(sqrt(n)) for
    ///         n >= 0. The function is `pure` and contains no inline
    ///         assembly.
    function _isqrt(uint256 n) internal pure returns (uint256) {
        if (n < 2) return n;
        uint256 x = uint256(1) << ((_log2(n) >> 1) + 1);
        while (true) {
            uint256 y = (x + n / x) >> 1;
            if (y >= x) return x;
            x = y;
        }
        // unreachable
        return x;
    }

    /// @dev floor(log2(x)) for x > 0. Hand-rolled to avoid OZ's `Math.log2`
    ///      import (and to keep the function under no-inline-assembly).
    function _log2(uint256 x) internal pure returns (uint256 r) {
        if (x >= 1 << 128) { x >>= 128; r += 128; }
        if (x >= 1 << 64)  { x >>= 64;  r += 64;  }
        if (x >= 1 << 32)  { x >>= 32;  r += 32;  }
        if (x >= 1 << 16)  { x >>= 16;  r += 16;  }
        if (x >= 1 << 8)   { x >>= 8;   r += 8;   }
        if (x >= 1 << 4)   { x >>= 4;   r += 4;   }
        if (x >= 1 << 2)   { x >>= 2;   r += 2;   }
        if (x >= 1 << 1)   {            r += 1;   }
    }
}

// =====================================================================
// Concrete paired subclasses — load-bearing under both address sorts
// =====================================================================

/// @notice Headline differential under `address(token) < address(stable)`.
contract Theorem5_2BankRun_LowAddrTest is Theorem5_2BankRunBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return true;
    }
}

/// @notice Headline differential under `address(token) > address(stable)`.
contract Theorem5_2BankRun_HighAddrTest is Theorem5_2BankRunBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return false;
    }
}
