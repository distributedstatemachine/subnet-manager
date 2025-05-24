// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script, console} from "forge-std/Script.sol";
import {SubtensorReader} from "../src/SubtensorReader.sol";

contract DeploySubtensorReaderScript is Script {
    function run() external {
        // Use FFI to get combined prefixes
        string[] memory ffiParamsSAIE = new string[](3);
        ffiParamsSAIE[0] = "node";
        ffiParamsSAIE[1] = "scripts/ffi/generateStorageKey.mjs";
        ffiParamsSAIE[2] = "combinedPrefix SubtensorModule SubnetAlphaInEmission";
        bytes memory saiePrefixBytes = vm.ffi(ffiParamsSAIE);
        bytes32 saiePrefix = vm.parseBytes32(string(saiePrefixBytes));

        string[] memory ffiParamsSAOE = new string[](3);
        ffiParamsSAOE[0] = "node";
        ffiParamsSAOE[1] = "scripts/ffi/generateStorageKey.mjs";
        ffiParamsSAOE[2] = "combinedPrefix SubtensorModule SubnetAlphaOutEmission";
        bytes memory saoePrefixBytes = vm.ffi(ffiParamsSAOE);
        bytes32 saoePrefix = vm.parseBytes32(string(saoePrefixBytes));

        string[] memory ffiParamsSTIE = new string[](3);
        ffiParamsSTIE[0] = "node";
        ffiParamsSTIE[1] = "scripts/ffi/generateStorageKey.mjs";
        ffiParamsSTIE[2] = "combinedPrefix SubtensorModule SubnetTaoInEmission";
        bytes memory stiePrefixBytes = vm.ffi(ffiParamsSTIE);
        bytes32 stiePrefix = vm.parseBytes32(string(stiePrefixBytes));

        string[] memory ffiParamsSAI = new string[](3);
        ffiParamsSAI[0] = "node";
        ffiParamsSAI[1] = "scripts/ffi/generateStorageKey.mjs";
        ffiParamsSAI[2] = "combinedPrefix SubtensorModule SubnetAlphaIn";
        bytes memory saiPrefixBytes = vm.ffi(ffiParamsSAI);
        bytes32 saiPrefix = vm.parseBytes32(string(saiPrefixBytes));

        string[] memory ffiParamsSAO = new string[](3);
        ffiParamsSAO[0] = "node";
        ffiParamsSAO[1] = "scripts/ffi/generateStorageKey.mjs";
        ffiParamsSAO[2] = "combinedPrefix SubtensorModule SubnetAlphaOut";
        bytes memory saoPrefixBytes = vm.ffi(ffiParamsSAO);
        bytes32 saoPrefix = vm.parseBytes32(string(saoPrefixBytes));

        console.log("Deploying SubtensorReader with FFI generated prefixes:");
        console.log("SAIE Prefix (SubnetAlphaInEmission):", vm.toString(saiePrefix));
        console.log("SAOE Prefix (SubnetAlphaOutEmission):", vm.toString(saoePrefix));
        console.log("STIE Prefix (SubnetTaoInEmission):", vm.toString(stiePrefix));
        console.log("SAI Prefix (SubnetAlphaIn):", vm.toString(saiPrefix));
        console.log("SAO Prefix (SubnetAlphaOut):", vm.toString(saoPrefix));

        vm.startBroadcast();
        SubtensorReader reader = new SubtensorReader(saiePrefix, saoePrefix, stiePrefix, saiPrefix, saoPrefix);
        vm.stopBroadcast();

        console.log("SubtensorReader deployed to:", address(reader));
        console.log("You can set this address in SUBTENSOR_READER_ADDRESS env var for QuerySubtensor.s.sol");
    }
}
