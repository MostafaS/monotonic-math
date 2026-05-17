// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IM2Token
/// @notice External surface of the M² ERC20 token. The token has a single
/// genesis mint, three immutable burn-authority addresses (hook, router, self),
/// a permissionless `redeem` entry point using `mulDiv(amount, T, S)` from
/// paper Lemma 4.2, and a view-only `floorPrice()` per paper eq. (1).
interface IM2Token is IERC20 {
    /// @notice Burn `amount` of the caller's tokens and pay out the
    /// floor-rounded stable proceeds `mulDiv(amount, T, S)` from the treasury.
    /// Reverts `SupplyExhausted` if `totalSupply() == 0`. Reverts `ZeroAmount`
    /// if `amount == 0`.
    function redeem(uint256 amount) external returns (uint256 stableOut);

    /// @notice View-only display function returning the floor as an 18-decimal
    /// fixed-point: `T * 10^(36 - d_s) / S`. NOT called inside `redeem`.
    /// Reverts `SupplyExhausted` when `totalSupply() == 0`.
    function floorPrice() external view returns (uint256);

    /// @notice Burn `amount` tokens from `from`. Callable only by the three
    /// immutable burn-authority addresses set at construction:
    /// hook, router, self (the token contract itself for the redeem path).
    function burnFromAuthorized(address from, uint256 amount) external;

    /// @notice Backing stablecoin address (immutable).
    function stable() external view returns (address);

    /// @notice Backing stablecoin decimals (immutable, `<= 18`).
    function stableDecimals() external view returns (uint8);

    /// @notice Treasury custody contract address (immutable).
    function treasury() external view returns (address);

    /// @notice Router address (immutable). One of the three burn authorities.
    function router() external view returns (address);

    /// @notice Hook address (immutable). One of the three burn authorities.
    function hook() external view returns (address);

    /// @notice The single genesis mint amount, immutable.
    function INITIAL_SUPPLY() external view returns (uint256);
}
