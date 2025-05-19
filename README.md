# Subnet Owner Operations System

This repository contains a system for managing a Subtensor subnet owner's coldkey operations (primarily stake management and APY distribution) using EVM smart contracts and precompiles, governed by a multi-signature wallet with a veto mechanism.

## System Components

1. **MultiSigWalletWithVeto**: A multi-signature wallet where one owner proposes actions, and other owners have a period to veto. If not sufficiently vetoed, the action becomes executable.

2. **StakeDistributor**: Manages the configuration and calculation logic for APY distribution. This contract does not hold funds or execute state-changing Subtensor operations directly.

3. **Subtensor Precompile Interfaces**: Solidity interfaces that define how smart contracts can call the Subtensor runtime's precompiled functions.

4. **Keeper**: An off-chain automation agent that triggers the periodic APY distribution process.

5. **SubtensorReader**: A contract that reads Subtensor storage values using pre-calculated storage key prefixes.

## Setup and Deployment

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js and npm (for the FFI scripts and Keeper)

### Installation

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd subnet-owner-operations
   ```

2. Install dependencies:
   ```bash
   forge install
   npm install # For the FFI scripts and Keeper
   ```

### Deployment

1. Deploy the SubtensorReader:
   ```bash
   # This uses FFI to generate storage key prefixes
   forge script script/SubtensorReader.s.sol:DeploySubtensorReaderScript --broadcast --ffi
   ```

2. Deploy the MultiSigWalletWithVeto:
   ```bash
   # Using default parameters
   forge script script/MultiSigWalletWithVeto.s.sol:MultiSigWalletWithVetoScript --broadcast
   
   # Using custom parameters
   INITIAL_OWNERS="0x123...,0x456..." VETOES_REQUIRED=2 VETO_DURATION=259200 \
   forge script script/MultiSigWalletWithVeto.s.sol:MultiSigWalletWithVetoScript --broadcast
   ```

3. Deploy the StakeDistributor:
   ```bash
   # Using the deployed MultiSigWalletWithVeto address
   MULTISIG_WALLET="0x789..." STAKING_PRECOMPILE="0x800..." \
   forge script script/StakeDistributor.s.sol:StakeDistributorScript --broadcast
   ```

4. Initialize the StakeDistributor:
   - Use the MultiSigWalletWithVeto to propose and execute a transaction to initialize the StakeDistributor
   - Set up the distribution targets and other parameters

5. Configure the Keeper:
   ```bash
   # Set environment variables
   export RPC_URL="https://your-rpc-url"
   export PRIVATE_KEY="your-private-key"
   export MULTISIG_ADDRESS="0x789..."
   export DISTRIBUTOR_ADDRESS="0xabc..."
   export STAKING_V2_ADDRESS="0x800..."
   export CHECK_INTERVAL_MINUTES="60"
   
   # Run the Keeper
   node scripts/keeper.js
   ```

## Usage

### SubtensorReader

The SubtensorReader contract provides a clean interface to query Subtensor storage values:

```bash
# Set the deployed reader address
export SUBTENSOR_READER_ADDRESS="0xdeployed_address"

# Query values for netuid 0 (default)
forge script script/QuerySubtensor.s.sol:QuerySubtensorScript --rpc-url <your_rpc>

# Query values for a specific netuid
NETUID_QUERY=1 forge script script/QuerySubtensor.s.sol:QuerySubtensorScript --rpc-url <your_rpc>
```

The SubtensorReader uses pre-calculated storage key prefixes generated via FFI during deployment, which makes the on-chain logic simpler and more gas-efficient.

### MultiSigWalletWithVeto

- **Propose a transaction**: Any owner can propose a transaction to be executed by the wallet.
- **Veto a transaction**: Other owners can veto a proposed transaction within the veto period.
- **Execute a transaction**: Anyone can execute a transaction that has passed the veto period without being cancelled.

### StakeDistributor

- **Calculate APY distribution**: The Keeper calls this function to determine how much APY to distribute to each target.
- **Report manual stake changes**: After manual stake transfers, the MultiSig must report the change to the StakeDistributor.
- **Confirm APY distribution**: After executing APY distribution transfers, the MultiSig confirms the distribution to update the StakeDistributor's state.

### Keeper

The Keeper script automates the APY distribution process:
1. Checks if it's time for a distribution
2. Calculates the APY earned
3. Proposes transfers to the MultiSig
4. Executes the transfers after the veto period
5. Confirms the distribution to update the StakeDistributor's state

## Technical Details

### Storage Key Generation

The system uses an FFI script (`scripts/ffi/generateStorageKey.mjs`) to generate Substrate storage key prefixes. This approach:

1. Moves the complex part of storage key generation (pallet and item name hashing) off-chain
2. Allows Solidity to work with pre-calculated prefixes
3. Makes the on-chain logic simpler and more gas-efficient

The script can be used directly for debugging:

```bash
# Generate a combined prefix
node scripts/ffi/generateStorageKey.mjs combinedPrefix SubtensorModule SubnetAlphaInEmission

# Generate a full storage key
node scripts/ffi/generateStorageKey.mjs fullKey SubtensorModule SubnetAlphaInEmission 1
```

### SubtensorStorage Library

The `SubtensorStorage` library provides a low-level interface to query the Frontier storage precompile. It:

1. Takes a fully assembled storage key as input
2. Performs a `staticcall` to the precompile
3. Decodes the SCALE-encoded u64 result
4. Handles errors and empty responses gracefully

### SubtensorReader Contract

The `SubtensorReader` contract provides a high-level interface to query Subtensor storage values. It:

1. Stores pre-calculated storage key prefixes as immutable state variables
2. SCALE-encodes the netuid parameter
3. Concatenates the prefix with the encoded netuid to form the full storage key
4. Calls the SubtensorStorage library to query the precompile

## Testing

Run the tests:
```bash
forge test
```

The tests include:
- Unit tests for the SubtensorStorage library with mocked precompile responses
- Unit tests for the SubtensorReader contract with mocked precompile responses
- Integration tests that can be run against a live node

## Security Considerations

- The MultiSigWalletWithVeto is the root of trust on the EVM side. Its security is paramount.
- The StakeDistributor is trusted to perform calculations correctly but cannot move funds; it only proposes plans or updates its state based on MultiSig actions.
- The Keeper is trusted to trigger the process and submit valid proposals. A malicious keeper could spam proposals, but cannot execute them or steal funds.
- Correctness of lastKnownStakeBalanceRao in StakeDistributor is vital and relies on the MultiSig owners diligently calling reportManualStakeChange after any non-APY stake movements they perform.
- The SubtensorReader and SubtensorStorage components are read-only and cannot modify state, making them inherently safer.

## License

MIT
