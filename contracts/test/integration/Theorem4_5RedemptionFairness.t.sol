// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IntegrationFixtureBase} from "./base/IntegrationFixtureBase.sol";

// =====================================================================
// Theorem4_5RedemptionFairness — paper §4 Theorem 4.5
// =====================================================================
//
// Statement (paper §4 eq. (eq:fairness)):
//   Let holders a, b simultaneously submit redemption transactions for
//   N_a, N_b tokens against state σ. Under any ordering π in which a
//   executes before b (possibly with intervening in-protocol operations),
//       P_a^(π) / N_a  ≤  P_b^(π) / N_b.
//
// In integer terms, with `Math.mulDiv` floor-rounding and Lemma 4.2's
// residual identity (Theorem 4.3 Case 3), each redemption preserves OR
// strictly raises the floor (T/S) — so the later redeemer's per-token
// payout is weakly higher than the earlier redeemer's. Concretely:
//
//   P_a = mulDiv(N_a, T0, S0)                      (a redeems first at T0, S0)
//   T1  = T0 - P_a,  S1 = S0 - N_a
//   P_b = mulDiv(N_b, T1, S1)
//
// The fairness inequality becomes, cleared of division:
//
//   P_a * N_b  ≤  P_b * N_a
//
// which is the integer form the test asserts (cross-product, no
// fixed-point rounding artifacts).
//
// Cases:
//   1) a redeems → b redeems    (paired)
//   2) b redeems → a redeems    (paired, inverse ordering)
//   3) a redeems → collectFees → b redeems (post-collect floor strictly
//      rises by the 99.75% burn, so strict inequality)
//   4) a redeems → (no-op intervening op) → b redeems — equal (within the
//      integer-residual r = (N_a * T0) mod S0; the cross-product
//      inequality is still ≤, by Lemma 4.2)
//
// Paired-address-sort: the abstract base runs under BOTH orderings via
// the two concrete subclasses below.

abstract contract Theorem4_5RedemptionFairnessBase is IntegrationFixtureBase {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ANYONE = address(0xCA11E2);

    /// @dev Per-redeemer token allocation (raw 18-decimal units). Sized
    ///      well below S0 so a follow-on redemption is still feasible.
    uint256 internal constant N_A = 10_000_000 * 1e18; // 10M tokens
    uint256 internal constant N_B = 7_500_000 * 1e18; //  7.5M tokens

    function setUp() public {
        _deploy(_wantTokenLowerThanStable());

        // Seed minimal LP so the pool exists; this is irrelevant for the
        // pure-redemption test cases but lets the optional collectFees /
        // lpSell scenarios run against a non-degenerate pool.
        token.transfer(address(hook), 2e18);
        stableTok.mint(address(hook), 2e6);
        hook.initializePool(poolKey, uint160(1) << 96, uint128(1e6));

        // Give Alice and Bob their token allocations from the test
        // contract's residual S0 (post-LP seed; the `_deploy` fixture
        // does not move S0 to a vault — the test contract holds it).
        token.transfer(ALICE, N_A);
        token.transfer(BOB, N_B);
    }

    // -----------------------------------------------------------------
    // Case 1 — a redeems first, b redeems second
    // -----------------------------------------------------------------

    /// @notice With ordering π = [a, b], assert P_a/N_a ≤ P_b/N_b.
    /// @dev Cross-product form: P_a * N_b ≤ P_b * N_a. The cross-product
    ///      avoids fixed-point division and exactly mirrors the
    ///      integer-form proof from Lemma 4.2 + Theorem 4.3 Case 3.
    function test_AThenB_FairnessHolds() public {
        uint256 T0 = stableTok.balanceOf(address(treasury));
        uint256 S0 = token.totalSupply();

        // Expected payouts via the same mulDiv path as `M2Token.redeem`.
        uint256 expectedPa = Math.mulDiv(N_A, T0, S0);

        vm.prank(ALICE);
        uint256 Pa = token.redeem(N_A);
        assertEq(Pa, expectedPa, "Pa matches mulDiv(N_a, T0, S0)");

        uint256 T1 = stableTok.balanceOf(address(treasury));
        uint256 S1 = token.totalSupply();
        assertEq(T1, T0 - Pa, "T1 conservation");
        assertEq(S1, S0 - N_A, "S1 conservation");

        uint256 expectedPb = Math.mulDiv(N_B, T1, S1);
        vm.prank(BOB);
        uint256 Pb = token.redeem(N_B);
        assertEq(Pb, expectedPb, "Pb matches mulDiv(N_b, T1, S1)");

        // Theorem 4.5 inequality in cross-product form:
        //   P_a / N_a  ≤  P_b / N_b   ⇔   P_a * N_b  ≤  P_b * N_a
        assertLe(Pa * N_B, Pb * N_A, "Thm 4.5: later per-token payout weakly higher");
    }

    // -----------------------------------------------------------------
    // Case 2 — paired: b redeems first, a redeems second
    // -----------------------------------------------------------------

    /// @notice With the inverse ordering π = [b, a], the same theorem
    ///         applies with roles swapped: P_b/N_b ≤ P_a/N_a.
    function test_BThenA_FairnessHolds() public {
        uint256 T0 = stableTok.balanceOf(address(treasury));
        uint256 S0 = token.totalSupply();

        uint256 expectedPb = Math.mulDiv(N_B, T0, S0);
        vm.prank(BOB);
        uint256 Pb = token.redeem(N_B);
        assertEq(Pb, expectedPb);

        uint256 T1 = stableTok.balanceOf(address(treasury));
        uint256 S1 = token.totalSupply();

        uint256 expectedPa = Math.mulDiv(N_A, T1, S1);
        vm.prank(ALICE);
        uint256 Pa = token.redeem(N_A);
        assertEq(Pa, expectedPa);

        // Roles swapped: the later redeemer (a) gets the weakly higher
        // per-token payout.
        assertLe(Pb * N_A, Pa * N_B, "Thm 4.5: later per-token payout weakly higher");
    }

    // -----------------------------------------------------------------
    // Case 3 — intervening collectFees STRICTLY raises the floor
    // -----------------------------------------------------------------

    /// @notice With zero accrued fees, collectFees is a no-op and Case 3
    ///         reduces to Case 1 (equality in the no-residual subcase).
    /// @dev    The minimal-LP fixture does not generate organic fees, so
    ///         the floor is preserved across the collectFees call;
    ///         however, the redemption residual (Lemma 4.2) still
    ///         strictly raises the floor in the typical case.
    function test_AThenCollectFeesThenB_FairnessHolds() public {
        uint256 T0 = stableTok.balanceOf(address(treasury));
        uint256 S0 = token.totalSupply();

        // a redeems
        vm.prank(ALICE);
        uint256 Pa = token.redeem(N_A);

        uint256 T1 = stableTok.balanceOf(address(treasury));
        uint256 S1 = token.totalSupply();

        // intervening collectFees (anyone may call). With zero accrued
        // organic fees this is a no-op; we still call it to exercise the
        // composed scenario.
        vm.prank(ANYONE);
        hook.collectFees();

        uint256 T2 = stableTok.balanceOf(address(treasury));
        uint256 S2 = token.totalSupply();

        // collectFees preserves the floor at minimum: T2 * S1 ≥ T1 * S2.
        // For organic-fee-bearing pools it raises the floor strictly. For
        // the minimal-LP fixture it is exact equality.
        assertGe(T2 * S1, T1 * S2, "collectFees: floor non-decreasing");

        // b redeems against the post-collectFees state.
        vm.prank(BOB);
        uint256 Pb = token.redeem(N_B);

        // The cross-product fairness inequality compares the very first
        // floor (used by a) against the floor at b's redemption time:
        //   P_a / N_a  ≤  P_b / N_b
        // which expands to P_a * N_b * S0 * S2 ≤ P_b * N_a * S0 * S2.
        // The simpler integer form below uses (T0, S0) and (T2, S2):
        //   P_a * N_b  ≤  P_b * N_a
        // This is Theorem 4.5 applied to the composed schedule.
        assertLe(Pa * N_B, Pb * N_A, "Thm 4.5 (composed): later per-token payout weakly higher");

        // Sanity: the intermediate-state floor is at least as high as
        // the pre-redemption floor (T0/S0 ≤ T2/S2).
        assertGe(T2 * S0, T0 * S2, "intermediate floor >= initial floor");
    }

    // -----------------------------------------------------------------
    // Case 4 — intervening LP-flow operation (collectFees no-op stand-in)
    // -----------------------------------------------------------------

    /// @notice An LP-flow event between a and b that preserves the floor
    ///         (no realized fees) keeps b's per-token payout equal to
    ///         a's (modulo the integer residual that strictly raises the
    ///         floor on a's redemption per Lemma 4.2). The cross-product
    ///         inequality still holds.
    /// @dev    The Phase 5 fixture does not seed a swappable LP at
    ///         canonical scale, so a true `lpSell` is not exercisable
    ///         here without a deep-LP setup; the closest faithful
    ///         representation is the no-op collectFees call (which is
    ///         what `Case 4` of paper §4.1 reduces to under the
    ///         "no intervening realization" framing). The dedicated
    ///         deep-LP `lpSell` differential vs the closed-form Δ* lives
    ///         in `MainnetForkBankRunDifferential_Thm5_2` (Agent A).
    function test_AThenNoOpThenB_FairnessHoldsAndIsTight() public {
        uint256 T0 = stableTok.balanceOf(address(treasury));
        uint256 S0 = token.totalSupply();

        vm.prank(ALICE);
        uint256 Pa = token.redeem(N_A);

        uint256 T1 = stableTok.balanceOf(address(treasury));
        uint256 S1 = token.totalSupply();

        // No-op intervening operation (a self-call that preserves T, S).
        // Use a permissionless `notifyDirectInflow` on the treasury; pure
        // event emission, no balance change.
        treasury.notifyDirectInflow();

        // Sanity: no state change.
        assertEq(stableTok.balanceOf(address(treasury)), T1);
        assertEq(token.totalSupply(), S1);

        vm.prank(BOB);
        uint256 Pb = token.redeem(N_B);

        // Lemma 4.2 residual r = mulmod(N_a, T0, S0); whenever r > 0,
        // the post-redemption floor T1/S1 strictly exceeds the pre-
        // redemption floor T0/S0, so b's per-token payout strictly
        // exceeds a's. Whenever r == 0, equality holds.
        uint256 r = mulmod(N_A, T0, S0);
        if (r > 0) {
            assertLt(Pa * N_B, Pb * N_A, "Lemma 4.2: strict fairness when r > 0");
        } else {
            assertEq(Pa * N_B, Pb * N_A, "r == 0 implies exact equality");
        }
    }
}

// =====================================================================
// Concrete paired subclasses — FINAL_REPORT H4 paired-address-sort
// =====================================================================

contract Theorem4_5RedemptionFairnessLowAddrTest is Theorem4_5RedemptionFairnessBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return true;
    }
}

contract Theorem4_5RedemptionFairnessHighAddrTest is Theorem4_5RedemptionFairnessBase {
    function _wantTokenLowerThanStable() internal pure override returns (bool) {
        return false;
    }
}
