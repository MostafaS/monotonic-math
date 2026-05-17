// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {InvariantFixture} from "./handlers/InvariantFixture.sol";

/// @title SupplyInvariant
/// @notice Paper §3.2: total supply is minted once at genesis and can
///         only decrease. No post-genesis mint path exists.
/// @dev    Asserts `S <= S0` after every handler call AND the handler's
///         ghost `totalMintedEver == S0` (constant). Optional bytecode
///         probe scans the M2Token runtime bytecode for a `mint(address,
///         uint256)` selector and asserts it is absent (defense-in-depth;
///         the canonical no-mint check lives in Phase 7's disassembly
///         audit).
contract SupplyInvariantTest is InvariantFixture {
    function setUp() public {
        _deployInvariantFixture();
        targetContract(address(handler));
    }

    /// @notice Total supply must be <= genesis (paper §3.2 supply cap).
    function invariant_SupplyCap() public view {
        require(tokenContract.totalSupply() <= S0, "supply exceeds genesis");
    }

    /// @notice Handler ghost: no minting after genesis.
    function invariant_NoMintAfterGenesis() public view {
        require(
            handler.totalMintedEver() == S0,
            "totalMintedEver drifted from genesis"
        );
    }

    /// @notice Supply must be monotonically non-increasing across every
    ///         observed op. The handler records (lastSBefore, lastSAfter).
    function invariant_SupplyMonotoneNonIncreasing() public view {
        if (handler.lastOp() == 0) return;
        require(
            handler.lastSAfter() <= handler.lastSBefore(),
            "supply increased on a handler op"
        );
    }

    /// @notice Defense-in-depth: scan deployed M2Token runtime bytecode for
    ///         the `mint(address,uint256)` selector. It MUST NOT appear.
    ///         Phase 7 augments this with a full disassembly check; here we
    ///         scan for the function-dispatch selector.
    function invariant_NoMintSelectorInBytecode() public view {
        bytes memory code = address(tokenContract).code;
        bytes4 mintSel = bytes4(keccak256("mint(address,uint256)"));
        require(
            !_bytecodeContainsSelector(code, mintSel),
            "mint(address,uint256) selector present in M2Token bytecode"
        );
    }

    /// @dev Naive bytewise scan for a 4-byte selector inside `code`.
    function _bytecodeContainsSelector(bytes memory code, bytes4 selector)
        internal
        pure
        returns (bool)
    {
        if (code.length < 4) return false;
        bytes1 s0 = bytes1(selector);
        bytes1 s1 = bytes1(selector << 8);
        bytes1 s2 = bytes1(selector << 16);
        bytes1 s3 = bytes1(selector << 24);
        uint256 end = code.length - 3;
        for (uint256 i = 0; i < end; ++i) {
            if (
                code[i] == s0 &&
                code[i + 1] == s1 &&
                code[i + 2] == s2 &&
                code[i + 3] == s3
            ) return true;
        }
        return false;
    }
}
