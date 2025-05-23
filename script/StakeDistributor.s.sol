// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {StakeDistributor} from "../src/StakeDistributor.sol";
import {MultiSigWalletWithVeto} from "../src/MultiSigWalletWithVeto.sol";

contract StakeDistributorScript is Script {
    // Default parameters
    address public constant DEFAULT_STAKING_PRECOMPILE = address(0x0000000000000000000000000000000000000800); // Example address, replace with actual
    uint256 public constant DEFAULT_DISTRIBUTION_INTERVAL = 1 days; // Default to daily distribution

    function run() public {
        // Get deployment parameters from environment variables or use defaults
        address stakingPrecompile = getStakingPrecompileAddress();
        address multiSigWallet = getMultiSigWalletAddress();
        uint256 distributionInterval = getDistributionInterval();

        // Validate parameters
        require(stakingPrecompile != address(0), "Invalid staking precompile address");
        require(multiSigWallet != address(0), "Invalid MultiSig wallet address");
        require(distributionInterval > 0, "Invalid distribution interval");

        // Log deployment parameters
        console.log("Deploying StakeDistributor with the following parameters:");
        console.log("Staking V2 Precompile:", stakingPrecompile);
        console.log("MultiSig Wallet (owner):", multiSigWallet);
        console.log("Distribution Interval:", distributionInterval, "seconds");

        // Deploy the contract
        vm.startBroadcast();

        StakeDistributor distributor = new StakeDistributor(stakingPrecompile, multiSigWallet, distributionInterval);

        vm.stopBroadcast();

        console.log("StakeDistributor deployed at:", address(distributor));
        console.log("");
        console.log("Next steps:");
        console.log("1. Use the MultiSigWalletWithVeto to initialize the StakeDistributor");
        console.log("2. Set up the distribution targets and other parameters");
        console.log("3. Configure the off-chain Keeper to monitor and trigger distributions");
    }

    function getStakingPrecompileAddress() internal returns (address) {
        return vm.envOr("STAKING_PRECOMPILE", DEFAULT_STAKING_PRECOMPILE);
    }

    function getMultiSigWalletAddress() internal returns (address) {
        string memory walletAddrStr = vm.envOr("MULTISIG_WALLET", string(""));

        if (bytes(walletAddrStr).length == 0) {
            console.log("No MultiSig wallet address provided via environment variable.");
            console.log("Please provide the address of an already deployed MultiSigWalletWithVeto.");
            revert("MultiSig wallet address required");
        }

        return vm.parseAddress(walletAddrStr);
    }

    function getDistributionInterval() internal returns (uint256) {
        return vm.envOr("DISTRIBUTION_INTERVAL", DEFAULT_DISTRIBUTION_INTERVAL);
    }
}
