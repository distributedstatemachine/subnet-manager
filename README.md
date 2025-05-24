# Subnet Owner Operations System

This repository contains a system for managing a Subtensor subnet owner's coldkey operations (primarily stake management and APY distribution) using EVM smart contracts and precompiles, governed by a multi-signature wallet with a veto mechanism.

## System Components

1. **MultiSigWalletWithVeto**: A multi-signature wallet where one owner proposes actions, and other owners have a period to veto. If not sufficiently vetoed, the action becomes executable.

2. **Distributor**: A perpetual reward distribution contract that receives stake transfers from subnet owners and automatically distributes daily staking rewards to configured recipients while keeping the principal locked forever. The contract stakes to a validator and earns APY, distributing only the rewards earned above the locked principal.

3. **Subtensor Precompile Interfaces**: Solidity interfaces that define how smart contracts can call the Subtensor runtime's precompiled functions.

4. **Keeper**: An off-chain automation agent (GitHub Action) that triggers the daily reward distribution process.

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

3. Deploy the Distributor:
   ```bash
   # Deploy with multiple recipients and proportions
   DISTRIBUTOR_OWNER=0x1234... \
   VALIDATOR_HOTKEY=0xabcd... \
   NETUID=1 \
   RECIPIENT_COLDKEYS="0x1111...,0x2222..." \
   RECIPIENT_PROPORTIONS="6000,4000" \
   forge script script/Distributor.s.sol:DistributorScript --broadcast --rpc-url $RPC_URL
   ```

4. Initialize the Distributor:
   ```bash
   # Set the contract's SS58 public key (owner only)
   cast send $DISTRIBUTOR_ADDRESS "setThisSs58PublicKey(bytes32)" $CONTRACT_SS58_KEY --private-key $PRIVATE_KEY
   
   # Transfer stake to the contract's SS58 address (this becomes locked principal)
   # The contract will automatically detect principal additions >10% of current principal
   ```

5. Configure the GitHub Action Keeper:
   ```bash
   # Add these secrets to your GitHub repository:
   # RPC_URL: Your Bittensor RPC endpoint
   # PRIVATE_KEY: Private key for account that calls executeTransfer()
   # DISTRIBUTOR_ADDRESS: Deployed contract address
   
   # The GitHub Action runs every 4 hours but only executes if ready
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

### Distributor

The Distributor operates as a perpetual reward distribution system:

#### Key Features:
- **Principal Protection**: All stake transferred to the contract becomes locked principal that can never be withdrawn
- **Automatic Reward Distribution**: Distributes daily staking rewards to configured recipients based on proportions
- **Block-Based Timing**: Uses 7200 blocks (1 day) intervals for accurate timing
- **Multiple Recipients**: Supports multiple recipients with configurable proportions (basis points)
- **Validator Staking**: Stakes to a specific validator and earns APY rewards

#### Workflow:
1. **Monthly Principal Addition**: Subnet owner transfers stake to the contract's SS58 address
2. **Automatic Detection**: Contract detects stake increases >10% of principal and locks them
3. **Daily Distribution**: GitHub Action calls `executeTransfer()` every day to distribute rewards
4. **Proportional Split**: Rewards are distributed to recipients based on their configured proportions
5. **Perpetual Operation**: Process continues indefinitely with principal locked forever

#### Key Functions:
- `setThisSs58PublicKey(bytes32)`: Set the contract's SS58 public key (owner only)
- `executeTransfer()`: Distribute daily rewards (called by automation)
- `updatePrincipal()`: Manually detect new principal additions
- `canExecuteTransfer()`: Check if ready for next distribution
- `getNextTransferAmount()`: Preview next distribution amount
- `updateRecipients()`: Update recipient list and proportions (owner only)

#### View Functions:
- `getStakedBalance()`: Current total staked balance
- `getLockedPrincipal()`: Amount of principal locked forever
- `getAvailableRewards()`: Rewards available above principal
- `blocksUntilNextTransfer()`: Blocks remaining until next distribution
- `getRecipient(uint256)`: Get recipient details by index

### GitHub Action Keeper

The automated keeper runs as a GitHub Action:

```yaml
# Runs every 4 hours
schedule:
  - cron: '0 */4 * * *'
```

The keeper:
1. Checks if 7200 blocks (1 day) have passed since last transfer
2. Calculates available rewards to distribute
3. Executes transfer if amount ≥ 1 TAO (existential amount)
4. Logs transfer details and remaining time if not ready
5. Handles errors gracefully and reports status

## Technical Details

### Reward Distribution Logic

The Distributor implements sophisticated reward distribution logic:

1. **Daily Rewards**: Only transfers rewards earned since the last distribution
2. **Growth Cap**: If rewards exceed 1% of principal, caps at 100 TAO fallback amount
3. **Fallback Distribution**: If no rewards earned, distributes 100 TAO if available above principal
4. **Principal Protection**: Ensures transfers never touch the locked principal
5. **Proportional Split**: Distributes total amount to recipients based on basis points (10000 = 100%)

### Block-Based Timing

Uses Bittensor's 12-second block time for accurate scheduling:
- 1 day = 7200 blocks
- More reliable than timestamp-based timing
- Resistant to clock manipulation

### Principal Detection

Automatically detects new principal additions:
- Monitors balance increases >10% of current principal
- Locks detected increases as additional principal
- Emits `PrincipalDetected` events for transparency
- Manual `updatePrincipal()` function for edge cases

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
- Unit tests for the Distributor contract with mocked precompile responses
- Tests for principal detection and reward distribution logic
- Tests for multiple recipients and proportional distribution
- Tests for block-based timing and transfer conditions
- Integration tests for the complete workflow

## Security Considerations

- **Principal Immutability**: Once stake is transferred to the Distributor, it becomes locked principal that can never be withdrawn, ensuring perpetual operation
- **Owner Limitations**: The owner can only update recipients and emergency withdraw native tokens, but cannot touch staked principal
- **Automated Execution**: The GitHub Action keeper cannot steal funds, only trigger legitimate reward distributions
- **Validator Risk**: The contract stakes to a specific validator, so validator performance affects rewards
- **Proportional Accuracy**: Recipient proportions must sum to exactly 10000 basis points (100%)
- **Block Timing**: Uses block numbers instead of timestamps for more reliable timing
- **Existential Amounts**: Ensures all transfers meet minimum existential requirements

## Example Configuration

```bash
# Deploy a distributor with 60% to team, 40% to investors
DISTRIBUTOR_OWNER=0x1234567890123456789012345678901234567890 \
VALIDATOR_HOTKEY=0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890 \
NETUID=1 \
RECIPIENT_COLDKEYS="0x1111111111111111111111111111111111111111111111111111111111111111,0x2222222222222222222222222222222222222222222222222222222222222222" \
RECIPIENT_PROPORTIONS="6000,4000" \
forge script script/Distributor.s.sol:DistributorScript --broadcast --rpc-url $RPC_URL
```

This creates a distributor that:
- Stakes to the specified validator
- Distributes 60% of daily rewards to the first recipient
- Distributes 40% of daily rewards to the second recipient
- Locks all transferred principal forever
- Operates perpetually without human intervention

## License

MIT
