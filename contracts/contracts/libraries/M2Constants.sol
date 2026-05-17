// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title M2Constants
/// @author M² / Monotonic Math
/// @notice Locked design parameters for the M² protocol. Every value here
///         corresponds to a parameter named in `paper §3` and is fixed at
///         deployment. There is no setter for any of these values in any
///         of the four immutable contracts (token, treasury, router, hook).
/// @dev    All names map 1:1 onto the implementation-plan "Locked Design
///         Parameters" table. Changing any value in this library is a
///         protocol-redefinition event and must be reviewed against the
///         paper.
library M2Constants {
    // -----------------------------------------------------------------
    // Token (paper §3.2)
    // -----------------------------------------------------------------

    /// @notice ERC-20 name of the M² token.
    string internal constant TOKEN_NAME = "Monotonic Math";

    /// @notice ERC-20 symbol of the M² token.
    string internal constant TOKEN_SYMBOL = "M2";

    /// @notice ERC-20 decimals of the M² token. Paper §3.2 fixes this at 18.
    uint8 internal constant TOKEN_DECIMALS = 18;

    /// @notice Total genesis supply, in token units (multiply by 10^18 for raw).
    ///         Paper §3.2: `S_0 = 10^9`.
    uint256 internal constant TOTAL_SUPPLY_TOKENS = 1_000_000_000;

    /// @notice Total genesis supply, in raw (18-decimal) units.
    uint256 internal constant TOTAL_SUPPLY_RAW =
        TOTAL_SUPPLY_TOKENS * (10 ** uint256(TOKEN_DECIMALS));

    // -----------------------------------------------------------------
    // Genesis allocation (paper §3.6, 75/25 split)
    // -----------------------------------------------------------------

    /// @notice LP seed in token units. Paper §3.6: `L_{t,0} = 7.5*10^8`.
    uint256 internal constant LP_SEED_TOKENS = 750_000_000;

    /// @notice LP seed in raw (18-decimal) units.
    uint256 internal constant LP_SEED_RAW =
        LP_SEED_TOKENS * (10 ** uint256(TOKEN_DECIMALS));

    /// @notice Vesting vault seed in token units. Paper §3.6: `2.5*10^8`.
    uint256 internal constant VESTING_SEED_TOKENS = 250_000_000;

    /// @notice Vesting vault seed in raw (18-decimal) units.
    uint256 internal constant VESTING_SEED_RAW =
        VESTING_SEED_TOKENS * (10 ** uint256(TOKEN_DECIMALS));

    // -----------------------------------------------------------------
    // Router (paper §3.5)
    // -----------------------------------------------------------------

    /// @notice Basis-points denominator (10_000 = 100.00%).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Treasury split, in basis points. Paper §3.5: 50%.
    /// @dev    Floor-to-treasury: `treasuryIn = stableAmount / 2`;
    ///         ceiling-to-buy:    `stableUsedForBuy = stableAmount - treasuryIn`.
    uint256 internal constant TREASURY_BPS = 5_000;

    // -----------------------------------------------------------------
    // Hook (paper §3.4 eq. 2)
    // -----------------------------------------------------------------

    /// @notice V4 LP-fee unit denominator: hundredths of a bip. The V4
    ///         constant `LPFeeLibrary.MAX_LP_FEE` MUST equal this value;
    ///         the hook's constructor asserts the invariant at deploy time
    ///         to detect a future V4 dependency bump.
    uint256 internal constant V4_MAX_LP_FEE = 1_000_000;

    /// @notice Buy fee = 0.10% under V4 hundredths-of-a-bip units.
    ///         Stable-input direction.
    uint24 internal constant BUY_FEE = 1_000;

    /// @notice Sell fee = 3.00% under V4 hundredths-of-a-bip units.
    ///         Token-input direction. Load-bearing for Theorem 5.2.
    uint24 internal constant SELL_FEE = 30_000;

    /// @notice Caller bounty for `collectFees`, in basis points: 0.25% per side.
    uint256 internal constant CALLER_BOUNTY_BPS = 25;

    // -----------------------------------------------------------------
    // Backing-stable limits (paper §3.2 overflow bound)
    // -----------------------------------------------------------------

    /// @notice Maximum permitted decimals of the backing stable. Paper §3.2
    ///         derives the overflow analysis assuming `d_s ≤ 18`.
    uint8 internal constant MAX_STABLE_DECIMALS = 18;

    // -----------------------------------------------------------------
    // Mock stable (test / Sepolia fallback)
    // -----------------------------------------------------------------

    /// @notice MockStable ERC-20 name.
    string internal constant MOCK_STABLE_NAME = "Mock USD";

    /// @notice MockStable ERC-20 symbol.
    string internal constant MOCK_STABLE_SYMBOL = "mUSD";

    /// @notice MockStable decimals (matches USDC).
    uint8 internal constant MOCK_STABLE_DECIMALS = 6;
}
