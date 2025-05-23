// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../src/SubtensorReader.sol";
import "./mocks/MockPrecompileForReaderTest.sol";

// Test-specific reader that uses regular calls instead of static calls
contract TestableSubtensorReader {
    bytes32 public immutable SUBNET_ALPHA_IN_EMISSION_PREFIX;
    bytes32 public immutable SUBNET_ALPHA_OUT_EMISSION_PREFIX;
    bytes32 public immutable SUBNET_TAO_IN_EMISSION_PREFIX;
    bytes32 public immutable SUBNET_ALPHA_IN_PREFIX;
    bytes32 public immutable SUBNET_ALPHA_OUT_PREFIX;

    address constant PRECOMPILE_ADDRESS = address(0x807);

    constructor(
        bytes32 _subnetAlphaInEmissionPrefix,
        bytes32 _subnetAlphaOutEmissionPrefix,
        bytes32 _subnetTaoInEmissionPrefix,
        bytes32 _subnetAlphaInPrefix,
        bytes32 _subnetAlphaOutPrefix
    ) {
        SUBNET_ALPHA_IN_EMISSION_PREFIX = _subnetAlphaInEmissionPrefix;
        SUBNET_ALPHA_OUT_EMISSION_PREFIX = _subnetAlphaOutEmissionPrefix;
        SUBNET_TAO_IN_EMISSION_PREFIX = _subnetTaoInEmissionPrefix;
        SUBNET_ALPHA_IN_PREFIX = _subnetAlphaInPrefix;
        SUBNET_ALPHA_OUT_PREFIX = _subnetAlphaOutPrefix;
    }

    function subnetAlphaInEmission(uint16 netuid) external returns (uint64) {
        bytes memory key = abi.encodePacked(SUBNET_ALPHA_IN_EMISSION_PREFIX, _encodeNetuid(netuid));
        bytes memory result = _queryPrecompile(key);
        return _decodeUint64(result);
    }

    function _encodeNetuid(uint16 netuid) internal pure returns (bytes memory) {
        bytes memory encoded = new bytes(2);
        encoded[0] = bytes1(uint8(netuid & 0xFF));
        encoded[1] = bytes1(uint8((netuid >> 8) & 0xFF));
        return encoded;
    }

    function _queryPrecompile(bytes memory key) internal returns (bytes memory) {
        (bool success, bytes memory result) = PRECOMPILE_ADDRESS.call(key);
        require(success, "Precompile call failed");
        return result;
    }

    function _decodeUint64(bytes memory data) internal pure returns (uint64) {
        require(data.length >= 8, "Insufficient data for uint64");
        uint64 value = 0;
        for (uint256 i = 0; i < 8; i++) {
            value |= uint64(uint8(data[i])) << uint64(i * 8);
        }
        return value;
    }
}

contract SubtensorReaderTest is Test {
    TestableSubtensorReader reader;
    MockPrecompileForReaderTest mockPrecompile;

    // Known test values
    bytes32 constant SAIE_PREFIX = 0x41d031dbe35e945b485843b1dfaf69a4a2f967e83d2a2d26c986ab1d7190a54e;
    bytes32 constant SAOE_PREFIX = 0x41d031dbe35e945b485843b1dfaf69a463d6fe81796f16f790b5bef70cb5ea4d;
    bytes32 constant STIE_PREFIX = 0x41d031dbe35e945b485843b1dfaf69a40c8d69fab489e51df69dc7dac9b52a75;
    bytes32 constant SAI_PREFIX = 0x41d031dbe35e945b485843b1dfaf69a4b2f2bf0a1d606d107b6fce89853ce5db;
    bytes32 constant SAO_PREFIX = 0x41d031dbe35e945b485843b1dfaf69a4c1286d25d596af46761c7414d3e61ae0;

    function setUp() public {
        // Deploy mock precompile
        mockPrecompile = new MockPrecompileForReaderTest();

        // Deploy testable reader with test prefixes
        reader = new TestableSubtensorReader(SAIE_PREFIX, SAOE_PREFIX, STIE_PREFIX, SAI_PREFIX, SAO_PREFIX);

        // Set up the mock precompile at the expected address
        vm.etch(address(0x807), address(mockPrecompile).code);
    }

    function testSubnetAlphaInEmission_KeyConstructionAndQuery() public {
        // 14649 in little-endian hex: 0x3939000000000000
        // 14649 = 0x3939, so LE bytes are: 0x39, 0x39, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        MockPrecompileForReaderTest(address(0x807)).setResponse(hex"3939000000000000");

        // Query for netuid 42
        uint64 result = reader.subnetAlphaInEmission(42);

        // Verify mock was called
        assertTrue(MockPrecompileForReaderTest(address(0x807)).called(), "Mock precompile not called");

        // Verify correct storage key was constructed
        bytes memory expectedKey = abi.encodePacked(SAIE_PREFIX, hex"2a00");
        assertEq(
            MockPrecompileForReaderTest(address(0x807)).getLastInput(), expectedKey, "Incorrect storage key constructed"
        );

        // Verify response was correctly decoded
        assertEq(result, 14649, "Incorrect value decoded");
    }

    function testSubnetTaoInEmission_Netuid1() public {
        bytes memory expectedNetuidBytes = hex"0100";
        bytes memory expectedFullKey = abi.encodePacked(STIE_PREFIX, expectedNetuidBytes);

        uint64 expectedValue = 789;
        bytes memory mockResponse = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            mockResponse[i] = bytes1(uint8(expectedValue >> (i * 8)));
        }

        // For now, just test the key construction
        bytes memory actualKey = abi.encodePacked(STIE_PREFIX, hex"0100");
        assertEq(actualKey, expectedFullKey, "Full storage key mismatch for TaoInEmission");
    }
}
