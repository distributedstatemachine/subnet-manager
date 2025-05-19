import { xxhashAsHex } from '@polkadot/util-crypto';
import { stringToU8a } from '@polkadot/util';
import { Buffer } from 'buffer';

/**
 * Converts a number to a little-endian byte buffer.
 * @param {number} value The number to convert.
 * @param {number} numBytes The number of bytes for the output.
 * @returns {Buffer}
 */
function toLittleEndianBytes(value, numBytes) {
    const buffer = Buffer.alloc(numBytes);
    for (let i = 0; i < numBytes; i++) {
        buffer[i] = (value >> (i * 8)) & 0xff;
    }
    return buffer;
}

/**
 * Generates a Substrate storage key component (pallet or item hash - 128-bit twox).
 * @param {string} name The name of the pallet or item.
 * @returns {string} The hex-encoded twox128 hash (0x prefixed).
 */
function generateComponentHash(name) {
    return xxhashAsHex(stringToU8a(name), 128);
}

/**
 * Generates the SCALE encoded netuid.
 * @param {string | number} netuidStr The netuid as a string or number.
 * @returns {string} The hex-encoded SCALE encoded netuid (WITHOUT 0x prefix).
 */
function generateScaleEncodedNetuidHex(netuidStr) {
    const netuid = parseInt(netuidStr);
    if (isNaN(netuid) || netuid < 0 || netuid > 65535) {
        throw new Error("Invalid netuid: must be a u16.");
    }
    const netuidBytes = toLittleEndianBytes(netuid, 2); // u16 is 2 bytes
    return netuidBytes.toString('hex');
}

/**
 * Generates a combined PalletHash + ItemHash prefix.
 * @param {string} palletName
 * @param {string} itemName
 * @returns {string} The 32-byte hex-encoded prefix (0x prefixed).
 */
function generateCombinedPrefix(palletName, itemName) {
    const palletHash = generateComponentHash(palletName).substring(2); // Remove 0x
    const itemHash = generateComponentHash(itemName).substring(2);   // Remove 0x
    return `0x${palletHash}${itemHash}`;
}

/**
 * Generates a full Substrate storage key.
 * @param {string} combinedPrefixHex Hex string of (palletHash+itemHash) (e.g., 0x123...abc...)
 * @param {string} scaleEncodedKeyPartsHex Hex string of scale encoded key parts (e.g., netuid as '2a00')
 * @returns {string} The full hex-encoded storage key (0x prefixed).
 */
function constructFullKeyFromCombinedPrefix(combinedPrefixHex, scaleEncodedKeyPartsHex) {
    return `${combinedPrefixHex}${scaleEncodedKeyPartsHex}`;
}

// --- Main Execution Logic ---
// Only run CLI logic if this file is executed directly (not imported)
if (import.meta.url === `file://${process.argv[1]}`) {
    const command = process.argv[2];
    const args = process.argv.slice(3);

    try {
        if (command === 'palletHash') {
            if (args.length !== 1) throw new Error("Usage: palletHash <palletName>");
            process.stdout.write(generateComponentHash(args[0]));
        } else if (command === 'itemHash') {
            if (args.length !== 1) throw new Error("Usage: itemHash <itemName>");
            process.stdout.write(generateComponentHash(args[0]));
        } else if (command === 'combinedPrefix') {
            if (args.length !== 2) throw new Error("Usage: combinedPrefix <palletName> <itemName>");
            process.stdout.write(generateCombinedPrefix(args[0], args[1]));
        } else if (command === 'scaleNetuidHex') {
            if (args.length !== 1) throw new Error("Usage: scaleNetuidHex <netuid>");
            process.stdout.write(generateScaleEncodedNetuidHex(args[0]));
        } else if (command === 'fullKey') {
            if (args.length !== 3) throw new Error("Usage: fullKey <palletName> <itemName> <netuid>");
            const combinedPrefix = generateCombinedPrefix(args[0], args[1]);
            const netuidHex = generateScaleEncodedNetuidHex(args[2]);
            process.stdout.write(constructFullKeyFromCombinedPrefix(combinedPrefix, netuidHex));
        } else {
            console.error(`Unknown command: ${command}`);
            console.error("Available commands: palletHash, itemHash, combinedPrefix, scaleNetuidHex, fullKey");
            process.exit(1);
        }
    } catch (e) {
        console.error(`Error: ${e.message}`);
        process.exit(1);
    }
}

// Export functions for use as a module
export {
    generateComponentHash,
    generateScaleEncodedNetuidHex,
    generateCombinedPrefix,
    constructFullKeyFromCombinedPrefix
}; 