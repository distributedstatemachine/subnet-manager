# Subnet Owner Operations System

This repository contains a system for managing a Subtensor subnet owner's coldkey operations (primarily stake management and APY distribution) using EVM smart contracts and precompiles, governed by a multi-signature wallet with a veto mechanism.

## System Components

1. **MultiSigWalletWithVeto**: A multi-signature wallet where one owner proposes actions, and other owners have a period to veto. If not sufficiently vetoed, the action becomes executable.

2. **StakeDistributor**: Manages the configuration and calculation logic for APY distribution. This contract does not hold funds or execute state-changing Subtensor operations directly.

3. **Subtensor Precompile Interfaces**: Solidity interfaces that define how smart contracts can call the Subtensor runtime's precompiled functions.

4. **Keeper**: An off-chain automation agent that triggers the periodic APY distribution process.

## Setup and Deployment

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js and npm (for the Keeper script)

### Installation

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd subnet-owner-operations
   ```

2. Install dependencies:
   ```bash
   forge install
   npm install # For the Keeper script
   ```

### Deployment

1. Deploy the MultiSigWalletWithVeto:
   ```bash
   # Using default parameters
   forge script script/MultiSigWalletWithVeto.s.sol:MultiSigWalletWithVetoScript --broadcast
   
   # Using custom parameters
   INITIAL_OWNERS="0x123...,0x456..." VETOES_REQUIRED=2 VETO_DURATION=259200 \
   forge script script/MultiSigWalletWithVeto.s.sol:MultiSigWalletWithVetoScript --broadcast
   ```

2. Deploy the StakeDistributor:
   ```bash
   # Using the deployed MultiSigWalletWithVeto address
   MULTISIG_WALLET="0x789..." STAKING_PRECOMPILE="0x800..." \
   forge script script/StakeDistributor.s.sol:StakeDistributorScript --broadcast
   ```

3. Initialize the StakeDistributor:
   - Use the MultiSigWalletWithVeto to propose and execute a transaction to initialize the StakeDistributor
   - Set up the distribution targets and other parameters

4. Configure the Keeper:
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

## Testing

Run the tests:
```bash
forge test
```

## Security Considerations

- The MultiSigWalletWithVeto is the root of trust on the EVM side. Its security is paramount.
- The StakeDistributor is trusted to perform calculations correctly but cannot move funds; it only proposes plans or updates its state based on MultiSig actions.
- The Keeper is trusted to trigger the process and submit valid proposals. A malicious keeper could spam proposals, but cannot execute them or steal funds.
- Correctness of lastKnownStakeBalanceRao in StakeDistributor is vital and relies on the MultiSig owners diligently calling reportManualStakeChange after any non-APY stake movements they perform.

## License

MIT
