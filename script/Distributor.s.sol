// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Distributor} from "../src/Distributor.sol";

contract DistributorScript is Script {
    function run() public {
        // Get deployment parameters from environment variables
        address owner = getOwnerAddress();
        bytes32 validatorHotkey = getValidatorHotkey();
        uint16 netuid = getNetuid();
        bytes32[] memory recipientColdkeys = getRecipientColdkeys();
        uint256[] memory proportions = getProportions();

        // Validate parameters
        require(owner != address(0), "Invalid owner address");
        require(validatorHotkey != bytes32(0), "Invalid validator hotkey");
        require(recipientColdkeys.length > 0, "No recipients provided");
        require(recipientColdkeys.length == proportions.length, "Array length mismatch");

        // Validate proportions sum to 10000
        uint256 totalProportion = 0;
        for (uint256 i = 0; i < proportions.length; i++) {
            totalProportion += proportions[i];
        }
        require(totalProportion == 10000, "Proportions must sum to 10000");

        // Log deployment parameters
        console.log("Deploying Distributor with the following parameters:");
        console.log("Owner:", owner);
        console.log("Validator Hotkey:", vm.toString(validatorHotkey));
        console.log("Netuid:", netuid);
        console.log("Number of recipients:", recipientColdkeys.length);

        for (uint256 i = 0; i < recipientColdkeys.length; i++) {
            console.log("Recipient", i, ":");
            console.log("  Coldkey:", vm.toString(recipientColdkeys[i]));
            console.log("  Proportion:", proportions[i], "basis points");
        }

        // Deploy the contract
        vm.startBroadcast();

        Distributor distributor = new Distributor(owner, validatorHotkey, netuid, recipientColdkeys, proportions);

        vm.stopBroadcast();

        console.log("Distributor deployed at:", address(distributor));
        console.log("");
        console.log("Next steps:");
        console.log("1. Set the contract's SS58 public key using setThisSs58PublicKey()");
        console.log("2. Transfer stake to the contract's SS58 address");
        console.log("3. Set up the GitHub Action cron job to call executeTransfer() daily");
        console.log("4. Monitor the contract for PrincipalDetected events when adding stake");
    }

    function getOwnerAddress() internal view returns (address) {
        string memory ownerStr = vm.envOr("DISTRIBUTOR_OWNER", string(""));

        if (bytes(ownerStr).length == 0) {
            console.log("Using deployer as owner (no DISTRIBUTOR_OWNER env var set)");
            return msg.sender;
        }

        return vm.parseAddress(ownerStr);
    }

    function getValidatorHotkey() internal view returns (bytes32) {
        string memory hotkeyStr = vm.envString("VALIDATOR_HOTKEY");
        return vm.parseBytes32(hotkeyStr);
    }

    function getNetuid() internal view returns (uint16) {
        return uint16(vm.envUint("NETUID"));
    }

    function getRecipientColdkeys() internal view returns (bytes32[] memory) {
        string memory coldkeysStr = vm.envString("RECIPIENT_COLDKEYS");

        // Parse comma-separated list of coldkeys
        bytes memory coldkeysBytes = bytes(coldkeysStr);
        uint256 coldkeyCount = 1; // At least one coldkey

        // Count commas to determine number of coldkeys
        for (uint256 i = 0; i < coldkeysBytes.length; i++) {
            if (coldkeysBytes[i] == bytes1(",")) {
                coldkeyCount++;
            }
        }

        // Create array of coldkeys
        bytes32[] memory coldkeys = new bytes32[](coldkeyCount);

        // Parse coldkeys
        uint256 coldkeyIndex = 0;
        uint256 startIndex = 0;

        for (uint256 i = 0; i <= coldkeysBytes.length; i++) {
            if (i == coldkeysBytes.length || coldkeysBytes[i] == bytes1(",")) {
                // Extract coldkey substring
                string memory coldkeyStr = substring(coldkeysStr, startIndex, i - startIndex);

                // Convert string to bytes32
                bytes32 coldkey = vm.parseBytes32(trim(coldkeyStr));
                coldkeys[coldkeyIndex] = coldkey;

                // Move to next coldkey
                coldkeyIndex++;
                startIndex = i + 1;
            }
        }

        return coldkeys;
    }

    function getProportions() internal view returns (uint256[] memory) {
        string memory proportionsStr = vm.envString("RECIPIENT_PROPORTIONS");

        // Parse comma-separated list of proportions
        bytes memory proportionsBytes = bytes(proportionsStr);
        uint256 proportionCount = 1; // At least one proportion

        // Count commas to determine number of proportions
        for (uint256 i = 0; i < proportionsBytes.length; i++) {
            if (proportionsBytes[i] == bytes1(",")) {
                proportionCount++;
            }
        }

        // Create array of proportions
        uint256[] memory proportions = new uint256[](proportionCount);

        // Parse proportions
        uint256 proportionIndex = 0;
        uint256 startIndex = 0;

        for (uint256 i = 0; i <= proportionsBytes.length; i++) {
            if (i == proportionsBytes.length || proportionsBytes[i] == bytes1(",")) {
                // Extract proportion substring
                string memory proportionStr = substring(proportionsStr, startIndex, i - startIndex);

                // Convert string to uint256
                uint256 proportion = vm.parseUint(trim(proportionStr));
                proportions[proportionIndex] = proportion;

                // Move to next proportion
                proportionIndex++;
                startIndex = i + 1;
            }
        }

        return proportions;
    }

    function substring(string memory str, uint256 startIndex, uint256 length) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(length);

        for (uint256 i = 0; i < length; i++) {
            result[i] = strBytes[startIndex + i];
        }

        return string(result);
    }

    function trim(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);

        // Find start (skip leading whitespace)
        uint256 start = 0;
        while (start < strBytes.length && (strBytes[start] == " " || strBytes[start] == "\t")) {
            start++;
        }

        // Find end (skip trailing whitespace)
        uint256 end = strBytes.length;
        while (end > start && (strBytes[end - 1] == " " || strBytes[end - 1] == "\t")) {
            end--;
        }

        // Extract trimmed string
        bytes memory result = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            result[i] = strBytes[start + i];
        }

        return string(result);
    }
}
