// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title SubtensorStorage
 * @dev Library for querying Subtensor pallet storage values via precompile using a pre-assembled key.
 */
library SubtensorStorage {
    // --------------------------------------------------------------------- //
    // CONSTANTS                                                             //
    // --------------------------------------------------------------------- //

    // Precompile address for storage queries (index 2055)
    address internal constant PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000807;

    // Pallet name hash: twox128("SubtensorModule")
    bytes16 internal constant PALLET_PREFIX = 0x658faa385070e074c85bf6b568cf0555;

    // Storage item name hashes
    bytes16 internal constant SUBNET_ALPHA_IN_EMISSION_PREFIX = 0x1905df3b2516a166b6f9fba54fef1cd8;
    bytes16 internal constant SUBNET_ALPHA_OUT_EMISSION_PREFIX = 0x25257fbc5458419b7bc7e8c44c521521;
    bytes16 internal constant SUBNET_TAO_IN_EMISSION_PREFIX = 0xdd62ae7237581e8f6a684f1ecae06215;
    bytes16 internal constant SUBNET_ALPHA_IN_PREFIX = 0x2ce12f7007574647d692ac7edf8b7a53;
    bytes16 internal constant SUBNET_ALPHA_OUT_PREFIX = 0x7837978cc6746112a2c9e680a18cfcb9;

    // --------------------------------------------------------------------- //
    // INTERNALS                                                             //
    // --------------------------------------------------------------------- //

    /**
     * SCALE-encode a `u16` (little-endian).
     */
    function _encodeNetuid(uint16 netuid) private pure returns (bytes2) {
        return bytes2(netuid); // solidity stores uint16 LE in bytesN
    }

    /**
     * Build the raw storage key:
     *    key = twox128(pallet) ++ twox128(item) ++ SCALE(key-arg)
     */
    function _buildStorageKey(bytes16 itemHash, uint16 netuid) private pure returns (bytes memory) {
        // 16 + 16 + 2 = 34 bytes
        return abi.encodePacked(PALLET_PREFIX, itemHash, _encodeNetuid(netuid));
    }

    /**
     * @dev Low-level call into the Frontier storage-query precompile.
     * Assumes the precompile returns SCALE-encoded u64 (8 bytes, little-endian).
     * @param fullStorageKey The fully assembled storage key.
     * @return value The u64 value.
     */
    function queryPrecompile(bytes memory fullStorageKey) internal view returns (uint64 value) {
        bytes memory out = new bytes(8); // Max size for u64
        bool success;

        assembly {
            success :=
                staticcall(
                    gas(), // gas
                    PRECOMPILE_ADDRESS, // address of precompile
                    add(fullStorageKey, 0x20), // input ptr (skip length)
                    mload(fullStorageKey), // input size
                    add(out, 0x20), // output ptr (skip length)
                    8 // output size (request up to 8 bytes for u64)
                )
        }

        uint256 returnedDataSize;
        assembly {
            returnedDataSize := returndatasize()
        }

        if (!success || returnedDataSize == 0) {
            return 0; // Call failed or no data (e.g., key not found)
        }

        // Decode little-endian bytes from 'out' buffer.
        // Only read up to 'returnedDataSize' or 8, whichever is smaller.
        uint64 tempValue = 0;
        uint256 maxBytesToRead = returnedDataSize < 8 ? returnedDataSize : 8;

        for (uint256 i = 0; i < maxBytesToRead;) {
            uint8 byteVal;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                byteVal := byte(0, mload(add(add(out, 0x20), i)))
            }
            tempValue |= uint64(byteVal) << uint64(i * 8);
            // solhint-disable-next-line no-plusplus
            i++;
        }
        return tempValue;
    }

    // --------------------------------------------------------------------- //
    // PUBLIC READ HELPERS                                                   //
    // --------------------------------------------------------------------- //

    function subnetAlphaInEmission(uint16 netuid) internal view returns (uint64) {
        return queryPrecompile(_buildStorageKey(SUBNET_ALPHA_IN_EMISSION_PREFIX, netuid));
    }

    function subnetAlphaOutEmission(uint16 netuid) internal view returns (uint64) {
        return queryPrecompile(_buildStorageKey(SUBNET_ALPHA_OUT_EMISSION_PREFIX, netuid));
    }

    function subnetTaoInEmission(uint16 netuid) internal view returns (uint64) {
        return queryPrecompile(_buildStorageKey(SUBNET_TAO_IN_EMISSION_PREFIX, netuid));
    }

    function subnetAlphaIn(uint16 netuid) internal view returns (uint64) {
        return queryPrecompile(_buildStorageKey(SUBNET_ALPHA_IN_PREFIX, netuid));
    }

    function subnetAlphaOut(uint16 netuid) internal view returns (uint64) {
        return queryPrecompile(_buildStorageKey(SUBNET_ALPHA_OUT_PREFIX, netuid));
    }
}
