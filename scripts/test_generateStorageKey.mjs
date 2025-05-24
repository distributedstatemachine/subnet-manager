#!/usr/bin/env node
// Test script for generateStorageKey.mjs
//
// Usage:
//   node scripts/test_generateStorageKey.mjs
//

import {
    generateComponentHash,
    generateScaleEncodedNetuidHex,
    generateCombinedPrefix
} from './ffi/generateStorageKey.mjs';

// ---------------------------------------------------------------------------
// Reference values from SubtensorStorage.sol
// ---------------------------------------------------------------------------

const EXPECTED = {
    // Pallet hash
    'SubtensorModule': '658faa385070e074c85bf6b568cf0555',

    // Storage item hashes
    'SubnetAlphaInEmission': '1905df3b2516a166b6f9fba54fef1cd8',
    'SubnetAlphaOutEmission': '25257fbc5458419b7bc7e8c44c521521',
    'SubnetTaoInEmission': 'dd62ae7237581e8f6a684f1ecae06215',
    'SubnetAlphaIn': '2ce12f7007574647d692ac7edf8b7a53',
    'SubnetAlphaOut': '7837978cc6746112a2c9e680a18cfcb9',

    // Combined prefixes (pallet + item)
    'SubtensorModule_SubnetAlphaInEmission': '658faa385070e074c85bf6b568cf05551905df3b2516a166b6f9fba54fef1cd8',
    'SubtensorModule_SubnetAlphaOutEmission': '658faa385070e074c85bf6b568cf055525257fbc5458419b7bc7e8c44c521521',
    'SubtensorModule_SubnetTaoInEmission': '658faa385070e074c85bf6b568cf0555dd62ae7237581e8f6a684f1ecae06215',
    'SubtensorModule_SubnetAlphaIn': '658faa385070e074c85bf6b568cf05552ce12f7007574647d692ac7edf8b7a53',
    'SubtensorModule_SubnetAlphaOut': '658faa385070e074c85bf6b568cf05557837978cc6746112a2c9e680a18cfcb9',

    // SCALE-encoded netuids
    'netuid_0': '0000',
    'netuid_1': '0100',
    'netuid_42': '2a00',
    'netuid_255': 'ff00',
    'netuid_256': '0001',
    'netuid_65535': 'ffff'
};

// ---------------------------------------------------------------------------
// Test functions
// ---------------------------------------------------------------------------

function testComponentHash() {
    console.log('Testing component hash generation...');
    let allPassed = true;

    // Test pallet hash
    const palletHash = generateComponentHash('SubtensorModule').slice(2); // Remove 0x
    const palletPassed = palletHash === EXPECTED['SubtensorModule'];
    console.log(`  SubtensorModule: ${palletPassed ? '✅' : '❌'}`);
    console.log(`    Expected: ${EXPECTED['SubtensorModule']}`);
    console.log(`    Actual:   ${palletHash}`);
    allPassed = allPassed && palletPassed;

    // Test storage item hashes
    const items = ['SubnetAlphaInEmission', 'SubnetAlphaOutEmission', 'SubnetTaoInEmission', 'SubnetAlphaIn', 'SubnetAlphaOut'];
    for (const item of items) {
        const hash = generateComponentHash(item).slice(2); // Remove 0x
        const passed = hash === EXPECTED[item];
        console.log(`  ${item}: ${passed ? '✅' : '❌'}`);
        console.log(`    Expected: ${EXPECTED[item]}`);
        console.log(`    Actual:   ${hash}`);
        allPassed = allPassed && passed;
    }

    return allPassed;
}

function testCombinedPrefix() {
    console.log('\nTesting combined prefix generation...');
    let allPassed = true;

    const items = ['SubnetAlphaInEmission', 'SubnetAlphaOutEmission', 'SubnetTaoInEmission', 'SubnetAlphaIn', 'SubnetAlphaOut'];
    for (const item of items) {
        const combined = generateCombinedPrefix('SubtensorModule', item).slice(2); // Remove 0x
        const expected = EXPECTED[`SubtensorModule_${item}`];
        const passed = combined === expected;
        console.log(`  SubtensorModule_${item}: ${passed ? '✅' : '❌'}`);
        console.log(`    Expected: ${expected}`);
        console.log(`    Actual:   ${combined}`);
        allPassed = allPassed && passed;
    }

    return allPassed;
}

function testScaleEncodedNetuid() {
    console.log('\nTesting SCALE-encoded netuid generation...');
    let allPassed = true;

    const netuids = [0, 1, 42, 255, 256, 65535];
    for (const netuid of netuids) {
        const encoded = generateScaleEncodedNetuidHex(netuid);
        const expected = EXPECTED[`netuid_${netuid}`];
        const passed = encoded === expected;
        console.log(`  netuid_${netuid}: ${passed ? '✅' : '❌'}`);
        console.log(`    Expected: ${expected}`);
        console.log(`    Actual:   ${encoded}`);
        allPassed = allPassed && passed;
    }

    return allPassed;
}

// ---------------------------------------------------------------------------
// Run tests
// ---------------------------------------------------------------------------

console.log('🧪 Testing generateStorageKey.mjs...\n');

const componentHashPassed = testComponentHash();
const combinedPrefixPassed = testCombinedPrefix();
const scaleEncodedNetuidPassed = testScaleEncodedNetuid();

const allPassed = componentHashPassed && combinedPrefixPassed && scaleEncodedNetuidPassed;

console.log(`\n${allPassed ? '🎉 All tests passed!' : '❌ Some tests failed!'}`);

if (!allPassed) {
    console.log("\nYou need to update the constants in SubtensorStorage.sol with the actual values shown above.");
}

process.exit(allPassed ? 0 : 1);