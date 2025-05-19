// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script, console} from "forge-std/Script.sol";
import {SubtensorReader} from "../src/SubtensorReader.sol";

contract QuerySubtensorScript is Script {
    SubtensorReader public reader;
    address internal constant PRECOMPILE_ADDR = 0x0000000000000000000000000000000000000807;

    function setUp() public {
        address readerAddress = vm.envAddress("SUBTENSOR_READER_ADDRESS");
        if (readerAddress == address(0)) {
            console.log("SUBTENSOR_READER_ADDRESS env var not set.");
            console.log("Please deploy SubtensorReader first using 'script/SubtensorReader.s.sol:DeploySubtensorReaderScript --ffi'.");
            revert("SubtensorReader address not provided.");
        }
        reader = SubtensorReader(readerAddress);
        console.log("Using SubtensorReader at:", address(reader));
    }

    function run() public {
        uint16 netuidToQuery = uint16(vm.envOr("NETUID_QUERY", uint256(0)));
        console.log("Querying Subtensor storage for netuid:", netuidToQuery);
        console.log("Targeting precompile via SubtensorReader:", PRECOMPILE_ADDR);
        console.log("---");

        uint64 alphaInEmission = reader.subnetAlphaInEmission(netuidToQuery);
        console.log("SubnetAlphaInEmission :", alphaInEmission);

        uint64 alphaOutEmission = reader.subnetAlphaOutEmission(netuidToQuery);
        console.log("SubnetAlphaOutEmission:", alphaOutEmission);

        uint64 taoInEmission = reader.subnetTaoInEmission(netuidToQuery);
        console.log("SubnetTaoInEmission   :", taoInEmission);

        uint64 alphaIn = reader.subnetAlphaIn(netuidToQuery);
        console.log("SubnetAlphaIn         :", alphaIn);

        uint64 alphaOut = reader.subnetAlphaOut(netuidToQuery);
        console.log("SubnetAlphaOut        :", alphaOut);
        
        console.log("---");
        console.log("Query finished.");
    }
} 