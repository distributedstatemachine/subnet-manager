// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MultiSigWalletWithVeto} from "../src/MultiSigWalletWithVeto.sol";

contract MultiSigWalletWithVetoScript is Script {
    // Default parameters
    uint256 public constant DEFAULT_VETO_DURATION = 3 days;
    uint256 public constant DEFAULT_VETO_REQUIREMENT = 2;
    
    function run() public {
        // Get deployment parameters from environment variables or use defaults
        address[] memory initialOwners = getInitialOwners();
        uint256 vetoesRequired = getVetoesRequired();
        uint256 vetoDuration = getVetoDuration();
        
        // Validate parameters
        require(initialOwners.length > 0, "No owners provided");
        require(vetoesRequired > 0 && vetoesRequired <= initialOwners.length - 1, "Invalid veto requirement");
        require(vetoDuration > 0, "Invalid veto duration");
        
        // Log deployment parameters
        console.log("Deploying MultiSigWalletWithVeto with the following parameters:");
        console.log("Number of initial owners:", initialOwners.length);
        for (uint256 i = 0; i < initialOwners.length; i++) {
            console.log("Owner", i, ":", initialOwners[i]);
        }
        console.log("Vetoes required to cancel:", vetoesRequired);
        console.log("Veto duration (seconds):", vetoDuration);
        
        // Deploy the contract
        vm.startBroadcast();
        
        MultiSigWalletWithVeto wallet = new MultiSigWalletWithVeto(
            initialOwners,
            vetoesRequired,
            vetoDuration
        );
        
        vm.stopBroadcast();
        
        console.log("MultiSigWalletWithVeto deployed at:", address(wallet));
    }
    
    function getInitialOwners() internal returns (address[] memory) {
        string memory ownersStr = vm.envOr("INITIAL_OWNERS", string(""));
        
        // If no owners provided via env, use default test owners
        if (bytes(ownersStr).length == 0) {
            address[] memory defaultOwners = new address[](3);
            defaultOwners[0] = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // Default test address 1
            defaultOwners[1] = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // Default test address 2
            defaultOwners[2] = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // Default test address 3
            
            console.log("Using default test owners");
            return defaultOwners;
        }
        
        // Parse comma-separated list of owner addresses
        bytes memory ownersBytes = bytes(ownersStr);
        uint256 ownerCount = 1; // At least one owner
        
        // Count commas to determine number of owners
        for (uint256 i = 0; i < ownersBytes.length; i++) {
            if (ownersBytes[i] == bytes1(",")) {
                ownerCount++;
            }
        }
        
        // Create array of owner addresses
        address[] memory owners = new address[](ownerCount);
        
        // Parse owner addresses
        uint256 ownerIndex = 0;
        uint256 startIndex = 0;
        
        for (uint256 i = 0; i <= ownersBytes.length; i++) {
            if (i == ownersBytes.length || ownersBytes[i] == bytes1(",")) {
                // Extract address substring
                string memory addressStr = substring(ownersStr, startIndex, i - startIndex);
                
                // Convert string to address
                address ownerAddress = parseAddress(addressStr);
                owners[ownerIndex] = ownerAddress;
                
                // Move to next owner
                ownerIndex++;
                startIndex = i + 1;
            }
        }
        
        return owners;
    }
    
    function getVetoesRequired() internal returns (uint256) {
        return vm.envOr("VETOES_REQUIRED", DEFAULT_VETO_REQUIREMENT);
    }
    
    function getVetoDuration() internal returns (uint256) {
        return vm.envOr("VETO_DURATION", DEFAULT_VETO_DURATION);
    }
    
    function substring(string memory str, uint256 startIndex, uint256 length) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(length);
        
        for (uint256 i = 0; i < length; i++) {
            result[i] = strBytes[startIndex + i];
        }
        
        return string(result);
    }
    
    function parseAddress(string memory addressStr) internal pure returns (address) {
        bytes memory addressBytes = bytes(addressStr);
        
        // Remove leading/trailing whitespace
        uint256 start = 0;
        uint256 end = addressBytes.length;
        
        while (start < end && (addressBytes[start] == ' ' || addressBytes[start] == '\t')) {
            start++;
        }
        
        while (end > start && (addressBytes[end - 1] == ' ' || addressBytes[end - 1] == '\t')) {
            end--;
        }
        
        // Check for 0x prefix
        bool hasPrefix = start + 2 <= end && 
                         addressBytes[start] == '0' && 
                         (addressBytes[start + 1] == 'x' || addressBytes[start + 1] == 'X');
        
        if (!hasPrefix) {
            revert("Address must start with 0x");
        }
        
        // Skip 0x prefix
        start += 2;
        
        // Check length
        require(end - start == 40, "Invalid address length");
        
        // Parse hex string to address
        bytes memory hexBytes = new bytes(end - start);
        for (uint256 i = 0; i < end - start; i++) {
            hexBytes[i] = addressBytes[start + i];
        }
        
        return address(parseHexString(string(hexBytes)));
    }
    
    function parseHexString(string memory hexStr) internal pure returns (uint160) {
        bytes memory hexBytes = bytes(hexStr);
        uint160 result = 0;
        
        for (uint256 i = 0; i < hexBytes.length; i++) {
            uint8 digit = uint8(hexBytes[i]);
            
            // Convert ASCII to hex value
            if (digit >= 48 && digit <= 57) {
                // 0-9
                digit -= 48;
            } else if (digit >= 65 && digit <= 70) {
                // A-F
                digit = digit - 65 + 10;
            } else if (digit >= 97 && digit <= 102) {
                // a-f
                digit = digit - 97 + 10;
            } else {
                revert("Invalid hex character");
            }
            
            result = result * 16 + digit;
        }
        
        return result;
    }
} 