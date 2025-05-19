// Verify the Subtensor twox128 constants.
//
// $ npm i -D xxhashjs
// $ node scripts/check_hashes.js
//

const XXH = require('xxhashjs')

// ---------------- helpers ---------------------------------------------------

/**
 * Return an 8-byte Buffer with the little-endian xxhash64 of `str`
 * using `seed` (0 or 1 for twox128).
 */
function xxhash64LE (str, seed) {
  // digest() ⇒ object with .toString(16) that holds the 64-bit hash BE
  const hexBE = XXH.h64(seed).update(str).digest().toString(16).padStart(16, '0')
  const bufBE = Buffer.from(hexBE, 'hex')       // big-endian bytes
  return Buffer.from(bufBE.reverse())           // flip ⇒ little-endian
}

/**
 * Substrate's twox128:  xxhash64(seed 0) || xxhash64(seed 1)
 */
function twox128 (str) {
  return Buffer.concat([xxhash64LE(str, 0), xxhash64LE(str, 1)])
}

function hex (buf) {
  return buf.toString('hex')
}

// ---------------- targets ---------------------------------------------------

const EXPECTED = {
  // pallet
  'SubtensorModule'        : '41d031dbe35e945b485843b1dfaf69a4',

  // storage items
  'SubnetAlphaInEmission'  : 'a2f967e83d2a2d26c986ab1d7190a54e',
  'SubnetAlphaOutEmission' : '63d6fe81796f16f790b5bef70cb5ea4d',
  'SubnetTaoInEmission'    : '0c8d69fab489e51df69dc7dac9b52a75',
  'SubnetAlphaIn'          : 'b2f2bf0a1d606d107b6fce89853ce5db',
  'SubnetAlphaOut'         : 'c1286d25d596af46761c7414d3e61ae0'
}

// ---------------- run -------------------------------------------------------

let allGood = true
for (const [name, expected] of Object.entries(EXPECTED)) {
  const got = twox128(name).toString('hex')
  const ok  = got === expected.toLowerCase()
  console.log(`${name.padEnd(25)}  ${ok ? '✅' : '❌'}  ${got}`)
  if (!ok) allGood = false
}

if (!allGood) {
  console.error('\n❌  Some hashes differ from the constants in SubtensorStorage.sol')
  process.exitCode = 1
} else {
  console.log('\n🎉  All constants match')
}