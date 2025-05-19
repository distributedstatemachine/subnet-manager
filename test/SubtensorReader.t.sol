// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/SubtensorReader.sol";

contract MockPrecompileForReaderTest {
    bytes public lastInput;
    bytes public response;
    bool public called;

    function setResponse(bytes memory _response) public {
        response = _response;
    }
    fallback(bytes calldata input) external returns (bytes memory) {
        called = true;
        lastInput = input;
        return response;
    }
}

contract SubtensorReaderTest is Test {
    SubtensorReader public reader;
    MockPrecompileForReaderTest mock;
    address MOCK_TARGET_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000807; // From SubtensorStorage

    // Use FFI-generated prefixes for consistency
    bytes32 testSaiePrefix = 0x41d031dbe35e945b485843b1dfaf69a4a2f967e83d2a2d26c986ab1d7190a54e;
    bytes32 testSaoePrefix = 0x41d031dbe35e945b485843b1dfaf69a463d6fe81796f16f790b5bef70cb5ea4d;
    bytes32 testStiePrefix = 0x41d031dbe35e945b485843b1dfaf69a40c8d69fab489e51df69dc7dac9b52a75;
    bytes32 testSaiPrefix  = 0x41d031dbe35e945b485843b1dfaf69a4b2f2bf0a1d606d107b6fce89853ce5db;
    bytes32 testSaoPrefix  = 0x41d031dbe35e945b485843b1dfaf69a4c1286d25d596af46761c7414d3e61ae0;

    function setUp() public {
        reader = new SubtensorReader(
            testSaiePrefix,
            testSaoePrefix,
            testStiePrefix,
            testSaiPrefix,
            testSaoPrefix
        );
        mock = new MockPrecompileForReaderTest();
        vm.etch(MOCK_TARGET_PRECOMPILE_ADDRESS, address(mock).code);
    }

    function testSubnetAlphaInEmission_KeyConstructionAndQuery() public {
        uint16 netuid = 42; // 0x002a -> SCALE LE 0x2a00
        bytes memory expectedNetuidBytes = hex"2a00";
        bytes memory expectedFullKey = abi.encodePacked(testSaiePrefix, expectedNetuidBytes);

        uint64 expectedValue = 12345;
        bytes memory mockResponse = new bytes(8);
        for (uint i = 0; i < 8; i++) {
            mockResponse[i] = bytes1(uint8(expectedValue >> (i * 8)));
        }
        mock.setResponse(mockResponse);

        uint64 actualValue = reader.subnetAlphaInEmission(netuid);

        assertEq(mock.called(), true, "Mock precompile not called");
        assertEq(mock.lastInput(), expectedFullKey, "Full storage key mismatch");
        assertEq(actualValue, expectedValue, "Returned value mismatch");
    }

    // Add similar tests for other functions like subnetAlphaOutEmission, etc.
    function testSubnetTaoInEmission_Netuid1() public {
        uint16 netuid = 1; // 0x0001 -> SCALE LE 0x0100
        bytes memory expectedNetuidBytes = hex"0100";
        bytes memory expectedFullKey = abi.encodePacked(testStiePrefix, expectedNetuidBytes);
        
        uint64 expectedValue = 789;
        bytes memory mockResponse = new bytes(8);
        for (uint i = 0; i < 8; i++) {
            mockResponse[i] = bytes1(uint8(expectedValue >> (i * 8)));
        }
        mock.setResponse(mockResponse);

        uint64 actualValue = reader.subnetTaoInEmission(netuid);
        
        assertEq(mock.called(), true, "Mock precompile not called for TaoInEmission");
        assertEq(mock.lastInput(), expectedFullKey, "Full storage key mismatch for TaoInEmission");
        assertEq(actualValue, expectedValue, "Returned value mismatch for TaoInEmission");
    }
} 