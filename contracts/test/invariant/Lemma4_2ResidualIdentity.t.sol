// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TestBase} from "../helpers/TestBase.sol";

/// @title Lemma4_2ResidualIdentity
/// @notice Paper Lemma 4.2 — for any `(T, S, N)` with `0 < N <= S` and
///         `T > 0`, the redemption-rounding residual identity holds:
///
///           r = mulmod(N, T, S)
///           P = mulDiv(N, T, S)
///           (T - P) * S == T * (S - N) + r          [exact]
///           r > 0  =>  (T - P) * S >  T * (S - N)   [strict]
///           r == 0 =>  (T - P) * S == T * (S - N)   [equality]
///
///         This is the integer-arithmetic foundation of floor monotonicity
///         on `redeem` (Theorem 4.3 case 3).
/// @dev    STATELESS fuzz: EDR picks random `(T_seed, S_seed, N_seed)`
///         tuples and the test bounds them into physical ranges. Run at
///         `>= 10_000 runs/property` per Phase 4 acceptance criteria.
contract Lemma4_2ResidualIdentityTest is TestBase {
    /// @notice Fuzz target. Inputs are unbounded uint256 seeds; the body
    ///         clamps via `bound` to `(T, S, N)` ranges that exercise the
    ///         lemma's preconditions (T > 0, 0 < N <= S, products fit in
    ///         uint256).
    function testFuzz_Lemma4_2_ExactIdentity(
        uint256 tSeed,
        uint256 sSeed,
        uint256 nSeed
    ) public pure {
        // S in [1, 10^30] — leaves headroom for T*S and (T-P)*S to fit in
        // uint256 (10^60 << 2^256 ≈ 1.158e77).
        uint256 S = bound(sSeed, 1, 1e30);
        // N in [1, S].
        uint256 N = bound(nSeed, 1, S);
        // T in [0, 10^30] — lemma is informative for T > 0 but identity
        // holds trivially at T = 0 (both sides become 0). Bound the lower
        // edge at 1 to focus the fuzz on non-trivial cases.
        uint256 T = bound(tSeed, 1, 1e30);

        uint256 r = mulmod(N, T, S);
        uint256 P = Math.mulDiv(N, T, S);

        // Bytecode-level Lemma 4.2 identity.
        require((T - P) * S == T * (S - N) + r, "Lemma 4.2 identity broken");

        // Strict / equality halves.
        if (r > 0) {
            require((T - P) * S > T * (S - N), "r > 0 must imply strict");
        } else {
            require((T - P) * S == T * (S - N), "r == 0 must imply equality");
        }
    }

    /// @notice Boundary: N == S exact divisibility. Forces r == 0 and
    ///         drains treasury exactly (`P == T`).
    function testFuzz_Lemma4_2_FullRedemption(uint256 tSeed, uint256 sSeed)
        public
        pure
    {
        uint256 S = bound(sSeed, 1, 1e30);
        uint256 T = bound(tSeed, 0, 1e30);
        uint256 N = S;
        uint256 r = mulmod(N, T, S);
        uint256 P = Math.mulDiv(N, T, S);
        require(r == 0, "full redemption: residual must be 0");
        require(P == T, "full redemption: P must equal T");
    }

    /// @notice Boundary: T = 0 — payout is always 0 regardless of (N, S).
    function testFuzz_Lemma4_2_ZeroTreasury(uint256 sSeed, uint256 nSeed)
        public
        pure
    {
        uint256 S = bound(sSeed, 1, 1e30);
        uint256 N = bound(nSeed, 1, S);
        uint256 T = 0;
        uint256 r = mulmod(N, T, S);
        uint256 P = Math.mulDiv(N, T, S);
        require(r == 0, "T=0: residual must be 0");
        require(P == 0, "T=0: P must be 0");
    }
}
