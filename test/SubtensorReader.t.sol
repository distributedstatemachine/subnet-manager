// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../src/SubtensorReader.sol";

/**
 * @title SubtensorReaderTest
 * @dev Test suite for SubtensorReader contract
 */
contract SubtensorReaderTest is Test {
    // The SubtensorReader contract instance
    SubtensorReader public reader;
    
    // RPC URL for the Subtensor node
    string constant RPC_URL = "http://localhost:9944";
    
    // Test netuid values
    uint16 constant EXISTING_NETUID = 1;
    uint16 constant NON_EXISTING_NETUID = 999;

    function setUp() public {
        // Fork the live chain (latest block).  If you need a specific block,
        // replace with: vm.createFork(RPC_URL, uint256(<blockNumber>));
        uint256 forkId = vm.createFork(RPC_URL);
        vm.selectFork(forkId);
        
        // Deploy the reader contract
        reader = new SubtensorReader();
    }

    function testSubnetAlphaInEmission() public {
        uint64 result = reader.subnetAlphaInEmission(EXISTING_NETUID);
        console.log("SubnetAlphaInEmission value:", result);
        assertGt(result, 0);
    }

    function testSubnetAlphaOutEmission() public {
        uint64 result = reader.subnetAlphaOutEmission(EXISTING_NETUID);
        console.log("SubnetAlphaOutEmission value:", result);
        assertGt(result, 0);
    }

    function testSubnetTaoInEmission() public {
        uint64 result = reader.subnetTaoInEmission(EXISTING_NETUID);
        console.log("SubnetTaoInEmission value:", result);
        assertGt(result, 0);
    }

    function testSubnetAlphaIn() public {
        uint64 result = reader.subnetAlphaIn(EXISTING_NETUID);
        console.log("SubnetAlphaIn value:", result);
        assertGt(result, 0);
    }

    function testSubnetAlphaOut() public {
        uint64 result = reader.subnetAlphaOut(EXISTING_NETUID);
        console.log("SubnetAlphaOut value:", result);
        assertGt(result, 0);
    }

    function testNonExistingNetuid() public {
        uint64 result = reader.subnetAlphaInEmission(NON_EXISTING_NETUID);
        // For non-existing netuid, we expect 0
        assertEq(result, 0, "Non-existing netuid should return 0");
    }
} 