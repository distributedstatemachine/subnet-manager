// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./SubtensorStorage.sol";

/**
 * @title SubtensorReader
 * @dev Facade contract for reading Subtensor storage values
 */
contract SubtensorReader {
    using SubtensorStorage for uint16;

    /**
     * @dev Query SubnetAlphaInEmission for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetAlphaInEmission value
     */
    function subnetAlphaInEmission(uint16 netuid) external view returns (uint64) {
        return SubtensorStorage.subnetAlphaInEmission(netuid);
    }

    /**
     * @dev Query SubnetAlphaOutEmission for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetAlphaOutEmission value
     */
    function subnetAlphaOutEmission(uint16 netuid) external view returns (uint64) {
        return SubtensorStorage.subnetAlphaOutEmission(netuid);
    }

    /**
     * @dev Query SubnetTaoInEmission for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetTaoInEmission value
     */
    function subnetTaoInEmission(uint16 netuid) external view returns (uint64) {
        return SubtensorStorage.subnetTaoInEmission(netuid);
    }

    /**
     * @dev Query SubnetAlphaIn for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetAlphaIn value
     */
    function subnetAlphaIn(uint16 netuid) external view returns (uint64) {
        return SubtensorStorage.subnetAlphaIn(netuid);
    }

    /**
     * @dev Query SubnetAlphaOut for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetAlphaOut value
     */
    function subnetAlphaOut(uint16 netuid) external view returns (uint64) {
        return SubtensorStorage.subnetAlphaOut(netuid);
    }
} 