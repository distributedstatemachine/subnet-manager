// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/SubtensorStorage.sol";

// Mock precompile contract for testing purposes
contract MockPrecompile {
    bytes public lastInput;
    bytes public response;
    bool public called;
    bool public shouldRevert;

    function setResponse(bytes memory _response) public {
        response = _response;
        shouldRevert = false;
    }
    function setShouldRevert(bool _revert) public {
        shouldRevert = _revert;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        called = true;
        lastInput = input;
        if (shouldRevert) {
            revert("MockPrecompile: Call reverted as requested");
        }
        return response;
    }
}

contract SubtensorStorageQueryTest is Test {
    MockPrecompile mock;
    // The PRECOMPILE_ADDRESS from SubtensorStorage will be mocked
    address MOCK_TARGET_PRECOMPILE_ADDRESS = SubtensorStorage.PRECOMPILE_ADDRESS;

    function setUp() public {
        mock = new MockPrecompile();
        vm.etch(MOCK_TARGET_PRECOMPILE_ADDRESS, address(mock).code);
    }

    function testQueryPrecompile_Success_Full8Bytes() public {
        bytes memory testKey = hex"0102030405060708090a"; // Dummy key
        uint64 expectedValue = 0x0807060504030201; // Example: 8 bytes LE
        
        bytes memory mockResponse = new bytes(8);
        for (uint i = 0; i < 8; i++) {
            mockResponse[i] = bytes1(uint8(expectedValue >> (i * 8)));
        }
        mock.setResponse(mockResponse);

        uint64 actualValue = SubtensorStorage.queryPrecompile(testKey);

        assertEq(mock.called(), true, "Mock precompile was not called");
        assertEq(mock.lastInput(), testKey, "Input to mock precompile mismatch");
        assertEq(actualValue, expectedValue, "Decoded value mismatch for full 8 bytes");
    }

    function testQueryPrecompile_Success_ShortResponse_4Bytes() public {
        bytes memory testKey = hex"aabbcc";
        uint64 expectedValue = 0x04030201; // Example: 4 bytes LE
        
        bytes memory mockResponse = new bytes(4);
         for (uint i = 0; i < 4; i++) {
            mockResponse[i] = bytes1(uint8(expectedValue >> (i * 8)));
        }
        mock.setResponse(mockResponse);

        uint64 actualValue = SubtensorStorage.queryPrecompile(testKey);
        assertEq(actualValue, expectedValue, "Decoded value mismatch for short 4 bytes");
    }
    
    function testQueryPrecompile_Success_ShortResponse_1Byte() public {
        bytes memory testKey = hex"dd";
        uint64 expectedValue = 0xAB; // Example: 1 byte LE
        
        bytes memory mockResponse = new bytes(1);
        mockResponse[0] = bytes1(uint8(expectedValue));
        mock.setResponse(mockResponse);

        uint64 actualValue = SubtensorStorage.queryPrecompile(testKey);
        assertEq(actualValue, expectedValue, "Decoded value mismatch for short 1 byte");
    }

    function testQueryPrecompile_EmptyResponse() public {
        bytes memory testKey = hex"eeff";
        bytes memory emptyResponse = new bytes(0);
        mock.setResponse(emptyResponse);

        uint64 actualValue = SubtensorStorage.queryPrecompile(testKey);
        assertEq(actualValue, 0, "Value should be 0 for empty response");
    }

    function testQueryPrecompile_PrecompileReverts() public {
        bytes memory testKey = hex"112233";
        mock.setShouldRevert(true); // Configure mock to revert

        // The staticcall itself will not revert the caller (SubtensorStorage)
        // but 'success' will be false.
        uint64 actualValue = SubtensorStorage.queryPrecompile(testKey);
        assertEq(actualValue, 0, "Value should be 0 if precompile call fails (reverts)");
    }
} 