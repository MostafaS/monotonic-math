// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title Vm
/// @notice Cheatcode interface for Hardhat v3's EDR Solidity-test runtime.
///         The EDR exposes the same cheatcode address and the same Vm
///         interface as Foundry; this declaration is local so the project
///         does NOT depend on `forge-std`. The cheatcode address is
///         `address(uint160(uint256(keccak256("hevm cheat code"))))` which
///         resolves to `0x7109709ECfa91a80626fF3989D68f67F5b1DD12D`.
/// @dev    Only the cheatcodes used by the M² test suite are declared. Add
///         to this interface as future tests demand more; do NOT import any
///         third-party `Vm` interface in its place.
interface Vm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function deal(address account, uint256 newBalance) external;
    function warp(uint256 newTimestamp) external;
    function roll(uint256 newHeight) external;
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata data) external;
    function expectEmit(
        bool checkTopic1,
        bool checkTopic2,
        bool checkTopic3,
        bool checkData
    ) external;
    function expectEmit(
        bool checkTopic1,
        bool checkTopic2,
        bool checkTopic3,
        bool checkData,
        address emitter
    ) external;
    function label(address account, string calldata newLabel) external;
    function addr(uint256 privateKey) external pure returns (address);
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function load(address target, bytes32 slot) external view returns (bytes32);
    function store(address target, bytes32 slot, bytes32 value) external;
    function chainId(uint256 newChainId) external;
    function fee(uint256 newBasefee) external;
    function snapshot() external returns (uint256);
    function revertTo(uint256 snapshotId) external returns (bool);
    function assume(bool condition) external pure;

    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
}

/// @title TestBase
/// @author M² / Monotonic Math
/// @notice Minimal base contract for Hardhat v3 EDR-backed Solidity tests.
///         Provides a local `Vm` cheatcode handle plus Foundry-style
///         assertion helpers without depending on `forge-std`.
/// @dev    Every `.t.sol` in this project must inherit `TestBase` and
///         reference `vm` and the `assertX` helpers from this contract.
///         Do NOT add a `forge-std` import anywhere in the project.
abstract contract TestBase {
    /// @notice The EDR cheatcode handle. Same address Foundry uses.
    Vm internal constant vm =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // -----------------------------------------------------------------
    // assertEq — equality
    // -----------------------------------------------------------------

    function assertEq(uint256 a, uint256 b) internal pure {
        if (a != b) {
            revert(
                string.concat(
                    "assertEq(uint256): ",
                    _toString(a),
                    " != ",
                    _toString(b)
                )
            );
        }
    }

    function assertEq(uint256 a, uint256 b, string memory message)
        internal
        pure
    {
        if (a != b) revert(message);
    }

    function assertEq(int256 a, int256 b) internal pure {
        if (a != b) revert("assertEq(int256): values not equal");
    }

    function assertEq(address a, address b) internal pure {
        if (a != b) revert("assertEq(address): values not equal");
    }

    function assertEq(address a, address b, string memory message)
        internal
        pure
    {
        if (a != b) revert(message);
    }

    function assertEq(bool a, bool b) internal pure {
        if (a != b) revert("assertEq(bool): values not equal");
    }

    function assertEq(bytes32 a, bytes32 b) internal pure {
        if (a != b) revert("assertEq(bytes32): values not equal");
    }

    function assertEq(string memory a, string memory b) internal pure {
        if (keccak256(bytes(a)) != keccak256(bytes(b))) {
            revert("assertEq(string): values not equal");
        }
    }

    function assertEq(bytes memory a, bytes memory b) internal pure {
        if (keccak256(a) != keccak256(b)) {
            revert("assertEq(bytes): values not equal");
        }
    }

    // -----------------------------------------------------------------
    // assertNotEq — inequality
    // -----------------------------------------------------------------

    function assertNotEq(uint256 a, uint256 b) internal pure {
        if (a == b) revert("assertNotEq(uint256): values are equal");
    }

    function assertNotEq(address a, address b) internal pure {
        if (a == b) revert("assertNotEq(address): values are equal");
    }

    // -----------------------------------------------------------------
    // Comparisons
    // -----------------------------------------------------------------

    function assertGt(uint256 a, uint256 b) internal pure {
        if (!(a > b)) {
            revert(
                string.concat(
                    "assertGt(uint256): ",
                    _toString(a),
                    " not > ",
                    _toString(b)
                )
            );
        }
    }

    function assertGt(uint256 a, uint256 b, string memory message)
        internal
        pure
    {
        if (!(a > b)) revert(message);
    }

    function assertGe(uint256 a, uint256 b) internal pure {
        if (!(a >= b)) {
            revert(
                string.concat(
                    "assertGe(uint256): ",
                    _toString(a),
                    " not >= ",
                    _toString(b)
                )
            );
        }
    }

    function assertGe(uint256 a, uint256 b, string memory message)
        internal
        pure
    {
        if (!(a >= b)) revert(message);
    }

    function assertLt(uint256 a, uint256 b) internal pure {
        if (!(a < b)) {
            revert(
                string.concat(
                    "assertLt(uint256): ",
                    _toString(a),
                    " not < ",
                    _toString(b)
                )
            );
        }
    }

    function assertLt(uint256 a, uint256 b, string memory message)
        internal
        pure
    {
        if (!(a < b)) revert(message);
    }

    function assertLe(uint256 a, uint256 b) internal pure {
        if (!(a <= b)) {
            revert(
                string.concat(
                    "assertLe(uint256): ",
                    _toString(a),
                    " not <= ",
                    _toString(b)
                )
            );
        }
    }

    function assertLe(uint256 a, uint256 b, string memory message)
        internal
        pure
    {
        if (!(a <= b)) revert(message);
    }

    // -----------------------------------------------------------------
    // Approximate comparisons (for V4 tick-rounding tolerances)
    // -----------------------------------------------------------------

    /// @notice Asserts that |a - b| <= maxDelta (absolute tolerance).
    function assertApproxEqAbs(uint256 a, uint256 b, uint256 maxDelta)
        internal
        pure
    {
        uint256 delta = a > b ? a - b : b - a;
        if (delta > maxDelta) {
            revert("assertApproxEqAbs: |a - b| > maxDelta");
        }
    }

    /// @notice Asserts that |a - b| / b <= maxPercentDelta (1e18 = 100%).
    ///         `b` must be non-zero.
    function assertApproxEqRel(uint256 a, uint256 b, uint256 maxPercentDelta)
        internal
        pure
    {
        if (b == 0) revert("assertApproxEqRel: b is zero");
        uint256 delta = a > b ? a - b : b - a;
        uint256 percentDelta = (delta * 1e18) / b;
        if (percentDelta > maxPercentDelta) {
            revert("assertApproxEqRel: relative delta exceeded");
        }
    }

    // -----------------------------------------------------------------
    // Boolean assertions
    // -----------------------------------------------------------------

    function assertTrue(bool condition) internal pure {
        if (!condition) revert("assertTrue: condition is false");
    }

    function assertTrue(bool condition, string memory message) internal pure {
        if (!condition) revert(message);
    }

    function assertFalse(bool condition) internal pure {
        if (condition) revert("assertFalse: condition is true");
    }

    function assertFalse(bool condition, string memory message) internal pure {
        if (condition) revert(message);
    }

    // -----------------------------------------------------------------
    // expectRevert helpers (thin wrappers for readability)
    // -----------------------------------------------------------------

    function expectRevert() internal {
        vm.expectRevert();
    }

    function expectRevert(bytes4 selector) internal {
        vm.expectRevert(selector);
    }

    function expectRevert(bytes memory data) internal {
        vm.expectRevert(data);
    }

    // -----------------------------------------------------------------
    // Invariant targeting (Foundry StdInvariant-compatible surface)
    // -----------------------------------------------------------------
    //
    // The EDR invariant runner reads `targetContracts()` / `targetSelectors()`
    // etc. as public getters via the same protocol Foundry's `forge` uses.
    // The internal `targetContract(address)` helper pushes onto the same
    // array, matching `forge-std/StdInvariant` semantics. No `forge-std`
    // import is required.

    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    address[] internal _targetedContracts;
    address[] internal _targetedSenders;
    address[] internal _excludedContracts;
    address[] internal _excludedSenders;
    FuzzSelector[] internal _targetedSelectors;

    function targetContract(address c) internal {
        _targetedContracts.push(c);
    }

    function targetSender(address s) internal {
        _targetedSenders.push(s);
    }

    function excludeContract(address c) internal {
        _excludedContracts.push(c);
    }

    function excludeSender(address s) internal {
        _excludedSenders.push(s);
    }

    function targetSelector(FuzzSelector memory sel) internal {
        _targetedSelectors.push(sel);
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    function excludeContracts() public view returns (address[] memory) {
        return _excludedContracts;
    }

    function excludeSenders() public view returns (address[] memory) {
        return _excludedSenders;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory) {
        return _targetedSelectors;
    }

    // -----------------------------------------------------------------
    // Fuzz-input bounding (Foundry-style helper)
    // -----------------------------------------------------------------

    /// @notice Clamp `x` into the inclusive range `[min_, max_]` deterministically.
    ///         When `x` is outside the range, the result wraps via modular
    ///         arithmetic so every input in `[0, 2^256-1]` maps onto the range.
    ///         This is the standard Foundry `bound` semantics; included locally
    ///         so invariant-handler harnesses don't depend on forge-std.
    function bound(uint256 x, uint256 min_, uint256 max_)
        internal
        pure
        returns (uint256)
    {
        if (min_ > max_) revert("bound: min > max");
        uint256 size = max_ - min_ + 1;
        if (size == 0) return min_; // range covers all of uint256
        return min_ + (x % size);
    }

    // -----------------------------------------------------------------
    // Internal: uint -> decimal string (small, dependency-free)
    // -----------------------------------------------------------------

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
