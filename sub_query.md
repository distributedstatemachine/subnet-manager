
Title  
──────  
EVM precompile wrapper: read SubtensorModule
storage values (`SubnetAlpha{In,Out}{,Emission}` and `SubnetTaoInEmission`)
from Solidity via the new storage-query precompile (index = 2055).

Goals  
─────  
1.  Provide a gas-cheap Solidity interface (library + thin façade contract) that any
    EVM contract can call with **one `staticcall`** to fetch the five `u64` values for
    an arbitrary `netuid`.  
2.  Foundry test-suite proving correctness against a dev-chain running
    the Subtensor pallet with the storage-query precompile enabled.  
3.  Keep every component drop-in – no changes to runtimes or pallets.

Pre-compile facts (Frontier)  
────────────────────────────  
• Index 2055 ⇒ address `0x0000000000000000000000000000000000000807`  
• Calldata  = **raw SCALE-encoded storage key**  
• Return    = raw SCALE-encoded value bytes (empty if key missing)  
• Read-only ⇒ call with `staticcall`.

Storage-key layout (FRAME v4)  
──────────────────────────────  
Key = `twox128(<pallet name>) ‖ twox128(<item name>) ‖ SCALE(keyParts…)`

• Pallet name = `"SubtensorModule"`  (NOTE: was “Subtensor” in early drafts)  
  – twox128(Pallet) =  
    `0x41d031dbe35e945b485843b1dfaf69a4`  
• Item names + hashes:

| Item                          | twox128(Item)                           |
| ----------------------------- | --------------------------------------- |
| `SubnetAlphaInEmission`       | `0xa2f967e83d2a2d26c986ab1d7190a54e`    |
| `SubnetAlphaOutEmission`      | `0x63d6fe81796f16f790b5bef70cb5ea4d`    |
| `SubnetTaoInEmission`         | `0x0c8d69fab489e51df69dc7dac9b52a75`    |
| `SubnetAlphaIn`               | `0xb2f2bf0a1d606d107b6fce89853ce5db`    |
| `SubnetAlphaOut`              | `0xc1286d25d596af46761c7414d3e61ae0`    |

`netuid` is a `u16` little-endian SCALE (e.g. 42 → `0x2a00`).

Solidity deliverables  
─────────────────────  
A. `SubtensorStorage.sol` (library)  
   • constant `address PRECOMPILE = 0x…0807`  
   • constants for pallet + five item prefixes (see table)  
   • private `_query(bytes key) -> uint64` that  
     - assembles `staticcall`,  
     - copies up to 8 bytes of return data,  
     - reverts on failure.  
       TODO: bump buffer if/when values > 64 bits.  
   • five public `internal view` fns:  
     `subnetAlphaInEmission(uint16 netuid)` etc. – each calls `_query`.

B. `SubtensorReader.sol` (thin façade)  
   – Expose the same five fns as `external view` so dApps / scripts don’t need
     `using` syntax.

Foundry test-suite (`forge test`)  
──────────────────────────────────  
1. Spin up anvil (or `substrate-contract-node`) with:  
     • Subtensor pallet included + some known non-zero values  
     • storage-query precompile registered at 2055  
2. Deploy `SubtensorReader` via Foundry’s `VM.createSelectFork()` or Hardhat RPC.  
3. For each item:  
   a. Off-chain read the pallet storage via RPC (`state_getStorage`) to
      obtain the expected `u64`.  
   b. Call the reader function; assert equality.  
4. Negative test: call with a non-existing `netuid`, expect zero.

Directory + filenames  
─────────────────────  
contracts/  
  ├─ SubtensorStorage.sol  
  └─ SubtensorReader.sol  
test/  
  └─ SubtensorReader.t.sol

Edge-cases / TODOs  
──────────────────  
• Multi-key maps: add helpers that accept additional SCALE-encoded keys.  
• Return data > 8 bytes: change `_query` to dynamic `bytes` return.  
• Gas optimisation: inline decode in assembly if hot-path.  
• Security: wrap in try/catch for chains where the precompile might be missing.

Ready for implementation.
