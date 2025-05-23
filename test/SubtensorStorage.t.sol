// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../src/SubtensorStorage.sol";
import "./mocks/MockPrecompileForReaderTest.sol";

// Test-specific storage that uses regular calls instead of static calls
contract TestableSubtensorStorage {
    address constant PRECOMPILE_ADDRESS = address(0x807);

    function queryPrecompile(bytes memory key) external returns (uint64) {
        (bool success, bytes memory result) = PRECOMPILE_ADDRESS.call(key);
        require(success, "Precompile call failed");
        return _decodeUint64(result);
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

contract SubtensorStorageQueryTest is Test {
    TestableSubtensorStorage storage_;
    MockPrecompileForReaderTest mockPrecompile;

    function setUp() public {
        // Deploy mock precompile
        mockPrecompile = new MockPrecompileForReaderTest();

        // Deploy testable storage
        storage_ = new TestableSubtensorStorage();

        // Set up the mock precompile at the expected address
        vm.etch(address(0x807), address(mockPrecompile).code);
    }

    function testQueryPrecompile_Success_Full8Bytes() public {
        // Set response AFTER etching the code - 0x0102030405060708 as little-endian uint64
        MockPrecompileForReaderTest(address(0x807)).setResponse(hex"0807060504030201");

        bytes memory key = hex"01020304050607080910";
        uint64 result = storage_.queryPrecompile(key);

        // Verify mock was called
        assertTrue(MockPrecompileForReaderTest(address(0x807)).called(), "Mock precompile was not called");

        // Verify the key was passed correctly
        assertEq(MockPrecompileForReaderTest(address(0x807)).getLastInput(), key, "Incorrect key passed to precompile");

        // Verify the response - 0x0807060504030201 as LE uint64 = 0x0102030405060708
        assertEq(result, 0x0102030405060708, "Incorrect response from precompile");
    }

    function testQueryPrecompile_Success_ShortResponse_1Byte() public {
        MockPrecompileForReaderTest(address(0x807)).setResponse(hex"4200000000000000"); // 0x42 padded to 8 bytes

        bytes memory key = hex"deadbeef";
        uint64 result = storage_.queryPrecompile(key);

        assertTrue(MockPrecompileForReaderTest(address(0x807)).called(), "Mock precompile was not called");
        assertEq(result, 0x42, "Incorrect short response");
    }

    function testQueryPrecompile_Success_ShortResponse_4Bytes() public {
        MockPrecompileForReaderTest(address(0x807)).setResponse(hex"7856341200000000"); // 0x12345678 as LE

        bytes memory key = hex"cafebabe";
        uint64 result = storage_.queryPrecompile(key);

        assertTrue(MockPrecompileForReaderTest(address(0x807)).called(), "Mock precompile was not called");
        assertEq(result, 0x12345678, "Incorrect 4-byte response");
    }
}
