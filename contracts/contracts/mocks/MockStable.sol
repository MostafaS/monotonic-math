// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {M2Constants} from "../libraries/M2Constants.sol";

/// @title MockStable
/// @author M² / Monotonic Math
/// @notice Canonical mock backing-stable used by the M² unit, invariant, and
///         Sepolia-fallback environments. Mimics USDC's 6-decimal layout.
///         The name "Mock USD", symbol "mUSD", and 6-decimal pin all live in
///         {M2Constants} to keep the locked design parameters in one place.
/// @dev    `mint` is intentionally **public** — this is a test-only token and
///         is NOT safe for production use. The M² protocol never instantiates
///         a `MockStable` on a deployment chain it intends to support
///         long-term; on mainnet the canonical backing stable is real USDC
///         (paper §3.2 "backing stable").
contract MockStable is ERC20 {
    /// @notice 6-decimal layout matching USDC.
    uint8 private constant _DECIMALS = M2Constants.MOCK_STABLE_DECIMALS;

    constructor() ERC20(M2Constants.MOCK_STABLE_NAME, M2Constants.MOCK_STABLE_SYMBOL) {}

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    /// @notice TEST-ONLY: mints `amount` of mUSD to `to`. Unrestricted on
    ///         purpose. Do not deploy this contract in any production setting.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
