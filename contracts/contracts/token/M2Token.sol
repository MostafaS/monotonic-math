// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IM2Token} from "../interfaces/IM2Token.sol";
import {IM2Treasury} from "../interfaces/IM2Treasury.sol";
import {M2Constants} from "../libraries/M2Constants.sol";
import {M2Errors} from "../libraries/M2Errors.sol";
import {IM2Events} from "../libraries/M2Events.sol";

/// @title M2Token — Monotonic Math (M²) fixed-supply ERC20 with redemption
/// @author M² / Monotonic Math
/// @notice ERC20 with a single genesis mint, EIP-2612 permit, and a
///         permissionless `redeem` entry point implementing paper Lemma 4.2
///         (`stableOut = floor(amount * T / S)`). Burn authority is restricted
///         to exactly three immutable addresses per paper §3.2: the V4 hook
///         (token-side LP fee burn), the revenue router (buy-and-burn), and
///         the token contract itself (self-call from `redeem`).
/// @dev    NO inheritance of Ownable / AccessControl / Pausable / UUPSUpgradeable.
///         NO admin, NO upgrade path, NO pause, NO rescue, NO post-genesis mint.
///         The constructor is the only path that reaches `_mint`.
contract M2Token is ERC20, ERC20Permit, IM2Token, IM2Events {
    // -----------------------------------------------------------------
    // Immutable state (paper §3.2 — all parameters fixed at genesis)
    // -----------------------------------------------------------------

    /// @dev Stored as IERC20 to use SafeERC20-free read-only access; the
    ///      backing-stable transfers happen in M2Treasury, which uses SafeERC20.
    IERC20 private immutable _STABLE;

    /// @dev Stable's `decimals()` value, cached at construction. Bounded `<= 18`.
    uint8 private immutable _STABLE_DECIMALS;

    /// @dev Treasury custody contract.
    IM2Treasury private immutable _TREASURY;

    /// @dev Burn-authority address #2 (revenue router buy-and-burn).
    address private immutable _ROUTER;

    /// @dev Burn-authority address #1 (V4 hook token-side fee burn).
    address private immutable _HOOK;

    /// @dev Genesis mint amount (raw 18-decimal units).
    uint256 private immutable _INITIAL_SUPPLY;

    // -----------------------------------------------------------------
    // Constructor (paper §3.2 + §3.6 step 8)
    // -----------------------------------------------------------------

    /// @notice Deploy the M² token and perform the single genesis mint.
    /// @param stable_         Backing ERC-20 (non-rebasing, no fee-on-transfer).
    /// @param treasury_       Immutable treasury custody contract.
    /// @param router_         Immutable revenue router (burn-authority #2).
    /// @param hook_           Immutable V4 hook / LP owner (burn-authority #1).
    /// @param mintRecipient   Sole recipient of the genesis `_mint` call;
    ///                        typically the genesis factory.
    /// @param initialSupply   Genesis supply (raw 18-decimal units).
    /// @dev Reverts:
    ///        - `DecimalsOutOfRange` if `stable_.decimals() > 18`;
    ///        - `ZeroAddress` for any zero address input.
    constructor(
        address stable_,
        address treasury_,
        address router_,
        address hook_,
        address mintRecipient,
        uint256 initialSupply
    )
        ERC20(M2Constants.TOKEN_NAME, M2Constants.TOKEN_SYMBOL)
        ERC20Permit(M2Constants.TOKEN_NAME)
    {
        // Zero-address rejections — centralized `M2Errors.ZeroAddress`
        // selector, shared with M2Treasury and M2RevenueRouter constructors.
        if (
            stable_ == address(0) ||
            treasury_ == address(0) ||
            router_ == address(0) ||
            hook_ == address(0) ||
            mintRecipient == address(0)
        ) revert M2Errors.ZeroAddress();

        // Read and bound the stable's decimals once. Paper §3.2 overflow
        // analysis assumes d_s <= 18; reverting `DecimalsOutOfRange` keeps
        // the floor-price 10^(36 - d_s) factor non-negative.
        uint8 d = IERC20Metadata(stable_).decimals();
        if (d > M2Constants.MAX_STABLE_DECIMALS) revert M2Errors.DecimalsOutOfRange();

        _STABLE = IERC20(stable_);
        _STABLE_DECIMALS = d;
        _TREASURY = IM2Treasury(treasury_);
        _ROUTER = router_;
        _HOOK = hook_;
        _INITIAL_SUPPLY = initialSupply;

        // Single genesis mint. After this constructor returns, NO code path
        // in this contract's bytecode reaches `_mint` from any external
        // entry point. Verified by Phase 7 bytecode disassembly.
        _mint(mintRecipient, initialSupply);
    }

    // -----------------------------------------------------------------
    // External: redemption (paper §3.2 + Lemma 4.2)
    // -----------------------------------------------------------------

    /// @inheritdoc IM2Token
    /// @dev CEI: compute payout from a pre-burn snapshot, burn the caller's
    ///      tokens, then pull from treasury. If the treasury transfer reverts,
    ///      the whole transaction reverts (atomic).
    function redeem(uint256 amount) external returns (uint256 stableOut) {
        if (amount == 0) revert M2Errors.ZeroAmount();

        uint256 S = totalSupply();
        if (S == 0) revert M2Errors.SupplyExhausted();

        uint256 T = _STABLE.balanceOf(address(_TREASURY));

        // Paper Lemma 4.2: floor-rounded payout
        //   stableOut = floor(amount * T / S)
        // OZ Math.mulDiv handles 512-bit intermediate precision; rounding
        // direction is floor (default), which is protocol-protective.
        stableOut = Math.mulDiv(amount, T, S);

        // Self-redeem burn path (paper §3.2: token is one of three burn
        // authorities by `address(this)` equality; direct `_burn` here is
        // equivalent to a self-call to `burnFromAuthorized` and is the
        // implementation choice documented in IM2Token).
        // Effects-before-interactions: burn first, then ask treasury to pay.
        _burn(msg.sender, amount);

        _TREASURY.payRedemption(msg.sender, stableOut);

        emit Redeemed(msg.sender, amount, stableOut);
    }

    // -----------------------------------------------------------------
    // External: authorized burn (paper §3.2 — three burn roles)
    // -----------------------------------------------------------------

    /// @inheritdoc IM2Token
    /// @dev The three-role enumeration is enforced inline (rather than via a
    ///      modifier) so the bytecode literally branches on each authority
    ///      address. A fourth burn-authority address would require a separate
    ///      contract change visible in the diff and in disassembly.
    function burnFromAuthorized(address from, uint256 amount) external {
        if (
            msg.sender != _HOOK &&
            msg.sender != _ROUTER &&
            msg.sender != address(this)
        ) {
            revert M2Errors.UnauthorizedBurner();
        }
        _burn(from, amount);
    }

    // -----------------------------------------------------------------
    // External views (paper §3.2 eq. 1)
    // -----------------------------------------------------------------

    /// @inheritdoc IM2Token
    /// @dev Returns the 18-decimal fixed-point floor `F = T * 10^(36 - d_s) / S`.
    ///      NEVER called inside `redeem`; `redeem` uses Math.mulDiv directly to
    ///      avoid scaling artifacts. Reverts `SupplyExhausted` on `S == 0`
    ///      (paper Lemma 4.2 attaches the revert to "the next floorPrice call";
    ///      `redeem` mirrors the same revert).
    function floorPrice() external view returns (uint256) {
        uint256 S = totalSupply();
        if (S == 0) revert M2Errors.SupplyExhausted();
        uint256 T = _STABLE.balanceOf(address(_TREASURY));
        // Upscale factor 10^(36 - d_s); guaranteed <= 10^36 since d_s <= 18.
        // Worst-case numerator T * scale <= 10^24 * 10^36 = 10^60 << 2^256.
        uint256 scale;
        unchecked {
            // 36 - _STABLE_DECIMALS is in [18, 36]; safe.
            scale = 10 ** (36 - uint256(_STABLE_DECIMALS));
        }
        return (T * scale) / S;
    }

    // -----------------------------------------------------------------
    // Immutable getters (IM2Token surface)
    // -----------------------------------------------------------------

    /// @inheritdoc IM2Token
    function stable() external view returns (address) {
        return address(_STABLE);
    }

    /// @inheritdoc IM2Token
    function stableDecimals() external view returns (uint8) {
        return _STABLE_DECIMALS;
    }

    /// @inheritdoc IM2Token
    function treasury() external view returns (address) {
        return address(_TREASURY);
    }

    /// @inheritdoc IM2Token
    function router() external view returns (address) {
        return _ROUTER;
    }

    /// @inheritdoc IM2Token
    function hook() external view returns (address) {
        return _HOOK;
    }

    /// @inheritdoc IM2Token
    function INITIAL_SUPPLY() external view returns (uint256) {
        return _INITIAL_SUPPLY;
    }
}
