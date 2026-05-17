// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AddressOrderingInvariantBase} from "./handlers/AddressOrderingInvariantBase.sol";

// =====================================================================
// AddressOrderingInvariant — concrete subclasses for the paired
// address-sort invariant lane. The shared abstract base (which carries
// the three `invariant_*` assertions and the `setUp` wiring) lives in
// `./handlers/AddressOrderingInvariantBase.sol` so the Hardhat-v3 EDR
// test-discovery glob (`test/invariant/*.t.sol`) does NOT pick up the
// abstract base as a concrete test contract.
//
// Both subclasses inherit the SAME invariant assertions from the base
// and run them against the SAME bytecode, differing only in the
// CREATE2-mined MockStable address ordering vs. the M2Token address.
// =====================================================================

/// @notice Runs Theorem 4.3 + invariant (iv) under
///         `address(stable) < address(token)` (stable is currency0).
contract AddressOrderingInvariant_StableLowTest is AddressOrderingInvariantBase {
    function _wantStableLowerThanToken() internal pure override returns (bool) {
        return true;
    }
}

/// @notice Runs Theorem 4.3 + invariant (iv) under
///         `address(stable) > address(token)` (token is currency0).
contract AddressOrderingInvariant_StableHighTest is AddressOrderingInvariantBase {
    function _wantStableLowerThanToken() internal pure override returns (bool) {
        return false;
    }
}
