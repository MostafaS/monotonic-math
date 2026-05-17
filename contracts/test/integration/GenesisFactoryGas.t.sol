// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {TestBase} from "../helpers/TestBase.sol";
import {M2V4Hook} from "../../contracts/hook/M2V4Hook.sol";
import {MockStable} from "../../contracts/mocks/MockStable.sol";
import {M2GenesisFactory} from "../../contracts/genesis/M2GenesisFactory.sol";
import {M2Constants} from "../../contracts/libraries/M2Constants.sol";

interface VmGetCodeGas {
    function getCode(string calldata artifactPath) external view returns (bytes memory);
}

// =====================================================================
// GenesisFactoryGasTest — measures gas usage of execute() for the
// canonical 2-recipient genesis ceremony. Acceptance criterion (plan
// §"Gas budget"): ≤ 30M gas (mainnet block limit).
// =====================================================================

contract GenesisFactoryGasTest is TestBase {
    VmGetCodeGas internal constant vmCheats =
        VmGetCodeGas(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant T0 = 1_000_000 * 1e6;
    uint256 internal constant LS0 = 750_000 * 1e6;

    address internal constant DEPOSITOR = address(0xDE9051704);
    address internal constant VESTING_A = address(0xBE9EF1C1A);
    address internal constant VESTING_B = address(0xBE9EF1C2B);

    function _predictCreate(address deployer, uint64 nonce)
        internal
        pure
        returns (address)
    {
        bytes memory rlp = abi.encodePacked(
            bytes1(0xd6),
            bytes1(0x94),
            deployer,
            bytes1(uint8(nonce))
        );
        return address(uint160(uint256(keccak256(rlp))));
    }

    function _predictCreate2(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
        ))));
    }

    function _mineHookSalt(address deployer, bytes32 initCodeHash)
        internal
        pure
        returns (bytes32, address)
    {
        for (uint256 i = 0; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address addr = _predictCreate2(deployer, salt, initCodeHash);
            if ((uint160(addr) & Hooks.ALL_HOOK_MASK) == Hooks.BEFORE_SWAP_FLAG) {
                return (salt, addr);
            }
        }
        revert("hook salt mine exhausted");
    }

    /// @notice Single-tx `execute()` gas measurement. Logs the gas spent
    ///         and asserts it is below the mainnet 30M block gas limit.
    function test_GenesisExecuteGasBenchmark() public {
        // Deploy V4 PoolManager helper.
        bytes memory deployerCode = vmCheats.getCode(
            "V4PoolManagerDeployer.sol:V4PoolManagerDeployer"
        );
        address da;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            da := create(0, add(deployerCode, 0x20), mload(deployerCode))
        }
        (bool ok, bytes memory ret) = da.call(
            abi.encodeWithSignature("deploy(address)", address(this))
        );
        require(ok, "pm deploy failed");
        IPoolManager pm = IPoolManager(abi.decode(ret, (address)));

        // Deploy MockStable (no ordering constraint for the gas test).
        MockStable stableTok = new MockStable();
        address stableAddr = address(stableTok);

        // Deploy the factory; mine its hook salt.
        M2GenesisFactory factory = new M2GenesisFactory();
        address predictedTreasury = _predictCreate(address(factory), 1);
        address predictedToken = _predictCreate(address(factory), 2);

        bytes memory hookCreationCode = type(M2V4Hook).creationCode;
        bytes memory hookInit = abi.encodePacked(
            hookCreationCode,
            abi.encode(address(pm), predictedToken, stableAddr, predictedTreasury)
        );
        (bytes32 hookSalt, ) = _mineHookSalt(address(factory), keccak256(hookInit));

        // Build the canonical params: 2 vesting recipients, duration=0
        // (test/§3.7 mass-dump configuration).
        address[] memory recipients = new address[](2);
        recipients[0] = VESTING_A;
        recipients[1] = VESTING_B;
        uint64[] memory starts = new uint64[](2);
        starts[0] = uint64(block.timestamp);
        starts[1] = uint64(block.timestamp);
        uint64[] memory durations = new uint64[](2);
        durations[0] = 0;
        durations[1] = 0;
        uint256[] memory allocs = new uint256[](2);
        allocs[0] = M2Constants.VESTING_SEED_RAW / 2;
        allocs[1] = M2Constants.VESTING_SEED_RAW - allocs[0];

        M2GenesisFactory.GenesisParams memory params = M2GenesisFactory
            .GenesisParams({
                stable: IERC20(stableAddr),
                poolManager: address(pm),
                depositor: DEPOSITOR,
                treasurySeed: T0,
                lpStableSeed: LS0,
                lpLiquidity: uint128(1e6),
                sqrtPriceX96Initial: uint160(1) << 96,
                tickSpacing: int24(60),
                hookSalt: hookSalt,
                hookCreationCode: hookCreationCode,
                vestingRecipients: recipients,
                vestingStarts: starts,
                vestingDurations: durations,
                vestingAllocations: allocs
            });

        stableTok.mint(address(this), T0 + LS0);
        stableTok.approve(address(factory), T0 + LS0);

        uint256 gasBefore = gasleft();
        factory.execute(params);
        uint256 gasUsed = gasBefore - gasleft();

        // Acceptance criterion: ≤ 30M gas (mainnet block limit).
        assertLt(gasUsed, 30_000_000, "genesis gas budget");

        emit GasBenchmark(gasUsed);

        // Sanity floor: a real execute() must spend at least 1M gas.
        assertGt(gasUsed, 1_000_000, "sanity: gas measurement plausible");

        // Surface the measured gas via a string-typed assertion message.
        // Uncomment the line below ONLY when refreshing the documented
        // benchmark in docs/v4_model_correspondence.md (forces failure
        // so the value prints in the test runner's output).
        // require(false, string.concat("M2_GENESIS_GAS=", _toString(gasUsed)));
    }

    event GasBenchmark(uint256 gasUsed);
}
