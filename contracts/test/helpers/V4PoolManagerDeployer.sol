// SPDX-License-Identifier: MIT
//
// V4 PoolManager deployer (0.8.26 compilation unit)
// -------------------------------------------------
//
// `@uniswap/v4-core/src/PoolManager.sol` is exact-pinned to
// `pragma solidity 0.8.26`. The M² code base is exact-pinned to
// `pragma solidity 0.8.34;`. Hardhat v3 supports both compilers in the
// same project (see hardhat.config.ts), but a SINGLE compilation unit
// must satisfy a SINGLE pragma — so a .t.sol file with `=0.8.34` cannot
// directly `import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol"`.
//
// This wrapper compiles under `^0.8.26` and exposes `deploy()` which
// creates a fresh PoolManager. The 0.8.34 .t.sol tests call this via
// the `IV4PoolManagerDeployer` interface, getting back an
// `IPoolManager` address. The bridge keeps the V4 dependency
// dimensionally clean without modifying M² code's pragma lock.
//
// solhint-disable-next-line compiler-version
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

contract V4PoolManagerDeployer {
    /// @notice Deploy a fresh V4 PoolManager with the given initial owner.
    /// @param initialOwner The address granted ProtocolFees ownership
    ///                     (irrelevant for unit tests; can be the
    ///                     deployer or `address(this)`).
    /// @return The deployed PoolManager address.
    function deploy(address initialOwner) external returns (address) {
        return address(new PoolManager(initialOwner));
    }
}
