// Keeper script for automating APY distribution
// This is a Node.js script that uses ethers.js to interact with the contracts

const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

// Load ABI files
const MultiSigABI = JSON.parse(fs.readFileSync(path.join(__dirname, '../out/MultiSigWalletWithVeto.sol/MultiSigWalletWithVeto.json'))).abi;
const DistributorABI = JSON.parse(fs.readFileSync(path.join(__dirname, '../out/StakeDistributor.sol/StakeDistributor.json'))).abi;
const StakingV2ABI = JSON.parse(fs.readFileSync(path.join(__dirname, '../out/interfaces/IStakingV2.sol/IStakingV2.json'))).abi;

// Configuration (should be loaded from environment variables or config file)
const config = {
    rpcUrl: process.env.RPC_URL || 'http://localhost:8545',
    privateKey: process.env.PRIVATE_KEY, // Private key of a MultiSig owner
    multiSigAddress: process.env.MULTISIG_ADDRESS,
    distributorAddress: process.env.DISTRIBUTOR_ADDRESS,
    stakingV2Address: process.env.STAKING_V2_ADDRESS,
    checkIntervalMinutes: parseInt(process.env.CHECK_INTERVAL_MINUTES || '60'),
    gasLimit: parseInt(process.env.GAS_LIMIT || '3000000'),
    gasPrice: ethers.utils.parseUnits(process.env.GAS_PRICE || '1', 'gwei')
};

// Setup provider and signer
const provider = new ethers.providers.JsonRpcProvider(config.rpcUrl);
const wallet = new ethers.Wallet(config.privateKey, provider);

// Contract instances
const multiSig = new ethers.Contract(config.multiSigAddress, MultiSigABI, wallet);
const distributor = new ethers.Contract(config.distributorAddress, DistributorABI, provider);
const stakingV2 = new ethers.Contract(config.stakingV2Address, StakingV2ABI, provider);

// Main function
async function main() {
    console.log('Starting APY distribution keeper...');

    // Run the check immediately, then set up interval
    await checkAndDistributeAPY();

    // Set up interval for periodic checks
    setInterval(checkAndDistributeAPY, config.checkIntervalMinutes * 60 * 1000);
}

// Check if APY distribution is needed and initiate the process
async function checkAndDistributeAPY() {
    try {
        console.log('Checking if APY distribution is needed...');

        // Get distribution configuration
        const distributorConfig = await distributor.getConfig();
        const lastDistTime = distributorConfig.lastDistTime.toNumber();
        const minInterval = distributorConfig.minDistInterval.toNumber();
        const currentTime = Math.floor(Date.now() / 1000);

        // Check if enough time has passed since last distribution
        if (currentTime < lastDistTime + minInterval) {
            console.log(`Not time yet. Next distribution possible at ${new Date((lastDistTime + minInterval) * 1000)}`);
            return;
        }

        // Calculate APY distribution
        const [operations, newExpectedBalance] = await distributor.calculateApyDistribution();

        if (operations.length === 0) {
            console.log('No APY to distribute or not enough time has passed.');
            return;
        }

        console.log(`Found ${operations.length} distribution operations to execute.`);

        // Propose each transfer operation
        const proposalIds = [];
        let totalDistributed = ethers.BigNumber.from(0);

        for (let i = 0; i < operations.length; i++) {
            const op = operations[i];
            console.log(`Proposing transfer of ${ethers.utils.formatEther(op.amountRao)} to ${op.destinationColdkey}`);

            // Encode the transferStake function call
            const transferData = stakingV2.interface.encodeFunctionData('transferStake', [
                op.destinationColdkey,
                distributorConfig.hotkey,
                distributorConfig.currentNetuid,
                distributorConfig.currentNetuid,
                op.amountRao
            ]);

            // Propose the transaction
            const tx = await multiSig.proposeTransaction(
                config.stakingV2Address,
                0,
                transferData,
                { gasLimit: config.gasLimit, gasPrice: config.gasPrice }
            );

            const receipt = await tx.wait();
            const event = receipt.events.find(e => e.event === 'ProposalSubmitted');
            const proposalId = event.args.proposalId;

            proposalIds.push(proposalId);
            totalDistributed = totalDistributed.add(op.amountRao);

            console.log(`Proposed transfer as proposal ID ${proposalId}`);
        }

        console.log(`All transfers proposed. Total amount: ${ethers.utils.formatEther(totalDistributed)}`);
        console.log(`Waiting for veto period and execution...`);

        // Store the proposals for later execution
        storeProposals(proposalIds, totalDistributed);

    } catch (error) {
        console.error('Error in APY distribution process:', error);
    }
}

// Store proposals for later execution
function storeProposals(proposalIds, totalDistributed) {
    const data = {
        proposalIds,
        totalDistributed: totalDistributed.toString(),
        timestamp: Date.now(),
        executed: false,
        confirmed: false
    };

    const pendingPath = path.join(__dirname, 'pending_distributions.json');
    let pendingDistributions = [];

    if (fs.existsSync(pendingPath)) {
        pendingDistributions = JSON.parse(fs.readFileSync(pendingPath));
    }

    pendingDistributions.push(data);
    fs.writeFileSync(pendingPath, JSON.stringify(pendingDistributions, null, 2));

    console.log(`Stored ${proposalIds.length} proposals for later execution.`);
}

// Check and execute pending proposals
async function checkPendingProposals() {
    const pendingPath = path.join(__dirname, 'pending_distributions.json');
    if (!fs.existsSync(pendingPath)) return;

    let pendingDistributions = JSON.parse(fs.readFileSync(pendingPath));
    let updated = false;

    for (let i = 0; i < pendingDistributions.length; i++) {
        const dist = pendingDistributions[i];

        // Skip already executed and confirmed distributions
        if (dist.executed && dist.confirmed) continue;

        // Execute proposals if not executed yet
        if (!dist.executed) {
            let allExecuted = true;

            for (const proposalId of dist.proposalIds) {
                const isExecutable = await multiSig.isProposalExecutable(proposalId);

                if (isExecutable) {
                    try {
                        console.log(`Executing proposal ${proposalId}...`);
                        const tx = await multiSig.executeTransaction(
                            proposalId,
                            { gasLimit: config.gasLimit, gasPrice: config.gasPrice }
                        );
                        await tx.wait();
                        console.log(`Proposal ${proposalId} executed successfully.`);
                    } catch (error) {
                        console.error(`Error executing proposal ${proposalId}:`, error);
                        allExecuted = false;
                    }
                } else {
                    console.log(`Proposal ${proposalId} is not executable yet.`);
                    allExecuted = false;
                }
            }

            if (allExecuted) {
                dist.executed = true;
                updated = true;
                console.log(`All proposals for distribution ${i} executed.`);
            }
        }

        // Confirm distribution if executed but not confirmed
        if (dist.executed && !dist.confirmed) {
            try {
                const distributorConfig = await distributor.getConfig();
                const currentStake = await stakingV2.getStake(
                    distributorConfig.hotkey,
                    distributorConfig.coldkey,
                    distributorConfig.currentNetuid
                );

                console.log(`Current stake after distribution: ${ethers.utils.formatEther(currentStake)}`);

                // Encode the confirmApyDistributionExecuted function call
                const confirmData = distributor.interface.encodeFunctionData('confirmApyDistributionExecuted', [
                    dist.totalDistributed,
                    currentStake
                ]);

                // Propose the confirmation transaction
                const tx = await multiSig.proposeTransaction(
                    config.distributorAddress,
                    0,
                    confirmData,
                    { gasLimit: config.gasLimit, gasPrice: config.gasPrice }
                );

                const receipt = await tx.wait();
                const event = receipt.events.find(e => e.event === 'ProposalSubmitted');
                const proposalId = event.args.proposalId;

                console.log(`Proposed confirmation as proposal ID ${proposalId}`);

                // Store the confirmation proposal
                dist.confirmationProposalId = proposalId;
                dist.confirmationProposed = true;
                updated = true;
            } catch (error) {
                console.error(`Error confirming distribution ${i}:`, error);
            }
        }

        // Check if confirmation proposal is executable
        if (dist.confirmationProposed && !dist.confirmed) {
            try {
                const isExecutable = await multiSig.isProposalExecutable(dist.confirmationProposalId);

                if (isExecutable) {
                    console.log(`Executing confirmation proposal ${dist.confirmationProposalId}...`);
                    const tx = await multiSig.executeTransaction(
                        dist.confirmationProposalId,
                        { gasLimit: config.gasLimit, gasPrice: config.gasPrice }
                    );
                    await tx.wait();
                    console.log(`Confirmation proposal executed successfully.`);

                    dist.confirmed = true;
                    updated = true;
                } else {
                    console.log(`Confirmation proposal ${dist.confirmationProposalId} is not executable yet.`);
                }
            } catch (error) {
                console.error(`Error executing confirmation proposal:`, error);
            }
        }
    }

    // Update the file if changes were made
    if (updated) {
        fs.writeFileSync(pendingPath, JSON.stringify(pendingDistributions, null, 2));
    }
}

// Run the keeper
async function runKeeper() {
    try {
        // Check for new APY to distribute
        await checkAndDistributeAPY();

        // Check and execute pending proposals
        await checkPendingProposals();
    } catch (error) {
        console.error('Error in keeper run:', error);
    }
}

// Start the keeper
if (require.main === module) {
    console.log('Starting APY distribution keeper...');

    // Run immediately, then set up interval
    runKeeper();
    setInterval(runKeeper, config.checkIntervalMinutes * 60 * 1000);
}

module.exports = {
    checkAndDistributeAPY,
    checkPendingProposals,
    runKeeper
}; 