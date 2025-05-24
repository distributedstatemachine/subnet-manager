// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./SubtensorStorage.sol";

/**
 * @title SubtensorReader
 * @dev Facade contract for reading Subtensor storage values.
 * It constructs the full storage key from pre-configured prefixes and a netuid.
 */
contract SubtensorReader {
    // These are (Pallet Hash + Item Hash) combined. Length = 16 + 16 = 32 bytes.
    // These are set during deployment using values from the FFI script.
    bytes32 public immutable KEY_PREFIX_SUBNET_ALPHA_IN_EMISSION;
    bytes32 public immutable KEY_PREFIX_SUBNET_ALPHA_OUT_EMISSION;
    bytes32 public immutable KEY_PREFIX_SUBNET_TAO_IN_EMISSION;
    bytes32 public immutable KEY_PREFIX_SUBNET_ALPHA_IN;
    bytes32 public immutable KEY_PREFIX_SUBNET_ALPHA_OUT;

    /**
     * @param saiePrefix twox128("SubtensorModule") || twox128("SubnetAlphaInEmission")
     * @param saoePrefix twox128("SubtensorModule") || twox128("SubnetAlphaOutEmission")
     * @param stiePrefix twox128("SubtensorModule") || twox128("SubnetTaoInEmission")
     * @param saiPrefix  twox128("SubtensorModule") || twox128("SubnetAlphaIn")
     * @param saoPrefix  twox128("SubtensorModule") || twox128("SubnetAlphaOut")
     */
    constructor(bytes32 saiePrefix, bytes32 saoePrefix, bytes32 stiePrefix, bytes32 saiPrefix, bytes32 saoPrefix) {
        KEY_PREFIX_SUBNET_ALPHA_IN_EMISSION = saiePrefix;
        KEY_PREFIX_SUBNET_ALPHA_OUT_EMISSION = saoePrefix;
        KEY_PREFIX_SUBNET_TAO_IN_EMISSION = stiePrefix;
        KEY_PREFIX_SUBNET_ALPHA_IN = saiPrefix;
        KEY_PREFIX_SUBNET_ALPHA_OUT = saoPrefix;
    }

    /**
     * @dev SCALE-encodes a u16 to 2 little-endian bytes.
     * e.g., netuid 42 (0x002a) -> 0x2a00
     */
    function _encodeNetuidToBytes(uint16 netuid) private pure returns (bytes memory) {
        bytes memory encoded = new bytes(2);
        encoded[0] = bytes1(uint8(netuid)); // LSB
        encoded[1] = bytes1(uint8(netuid >> 8)); // MSB
        return encoded;
    }

    /**
     * @dev Constructs the full storage key and queries the precompile.
     * @param keyPrefix The (PalletHash || ItemHash).
     * @param netuid The network UID.
     * @return The u64 value from storage.
     */
    function _queryWithPrefix(bytes32 keyPrefix, uint16 netuid) private view returns (uint64) {
        bytes memory scaleEncodedNetuid = _encodeNetuidToBytes(netuid);
        // Key: keyPrefix (32 bytes) || scaleEncodedNetuid (2 bytes) = 34 bytes total
        bytes memory fullStorageKey = abi.encodePacked(keyPrefix, scaleEncodedNetuid);
        return SubtensorStorage.queryPrecompile(fullStorageKey);
    }

    /**
     * @dev Query SubnetAlphaInEmission for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetAlphaInEmission value
     */
    function subnetAlphaInEmission(uint16 netuid) external view returns (uint64) {
        return _queryWithPrefix(KEY_PREFIX_SUBNET_ALPHA_IN_EMISSION, netuid);
    }

    /**
     * @dev Query SubnetAlphaOutEmission for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetAlphaOutEmission value
     */
    function subnetAlphaOutEmission(uint16 netuid) external view returns (uint64) {
        return _queryWithPrefix(KEY_PREFIX_SUBNET_ALPHA_OUT_EMISSION, netuid);
    }

    /**
     * @dev Query SubnetTaoInEmission for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetTaoInEmission value
     */
    function subnetTaoInEmission(uint16 netuid) external view returns (uint64) {
        return _queryWithPrefix(KEY_PREFIX_SUBNET_TAO_IN_EMISSION, netuid);
    }

    /**
     * @dev Query SubnetAlphaIn for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetAlphaIn value
     */
    function subnetAlphaIn(uint16 netuid) external view returns (uint64) {
        return _queryWithPrefix(KEY_PREFIX_SUBNET_ALPHA_IN, netuid);
    }

    /**
     * @dev Query SubnetAlphaOut for a given netuid
     * @param netuid The subnet ID
     * @return The SubnetAlphaOut value
     */
    function subnetAlphaOut(uint16 netuid) external view returns (uint64) {
        return _queryWithPrefix(KEY_PREFIX_SUBNET_ALPHA_OUT, netuid);
    }
}
