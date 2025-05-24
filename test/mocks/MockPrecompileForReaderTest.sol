// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract MockPrecompileForReaderTest {
    bytes private response;
    bool private wasCalled;
    bytes private lastInput;

    function called() external view returns (bool) {
        return wasCalled;
    }

    function getLastInput() external view returns (bytes memory) {
        return lastInput;
    }

    function setResponse(bytes memory _response) external {
        response = _response;
        wasCalled = false; // Reset called flag
    }

    // For regular calls - record the call and return response
    fallback(bytes calldata input) external returns (bytes memory) {
        lastInput = input;
        wasCalled = true;
        return response;
    }
}
