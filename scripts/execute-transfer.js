const { ethers } = require('ethers');
require('dotenv').config();

const DISTRIBUTOR_ABI = [
    "function canExecuteTransfer() external view returns (bool)",
    "function executeTransfer() external",
    "function getNextTransferAmount() external view returns (uint256)",
    "function blocksUntilNextTransfer() external view returns (uint256)",
    "event StakeTransferred(uint256 amount, uint256 newBalance)",
    "event TransferSkipped(string reason, uint256 calculatedAmount)"
];

async function main() {
    // Setup provider and wallet
    const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

    // Connect to distributor contract
    const distributor = new ethers.Contract(
        process.env.DISTRIBUTOR_ADDRESS,
        DISTRIBUTOR_ABI,
        wallet
    );

    console.log(`Checking distributor at ${process.env.DISTRIBUTOR_ADDRESS}`);

    try {
        // Check if transfer can be executed
        const canExecute = await distributor.canExecuteTransfer();

        if (!canExecute) {
            const blocksLeft = await distributor.blocksUntilNextTransfer();
            const hoursLeft = (Number(blocksLeft) * 12) / 3600; // 12 seconds per block
            console.log(`Transfer not ready. ${blocksLeft} blocks (~${hoursLeft.toFixed(1)} hours) remaining`);
            return;
        }

        // Get transfer amount
        const transferAmount = await distributor.getNextTransferAmount();
        const transferAmountTAO = ethers.formatUnits(transferAmount, 9); // 9 decimals for TAO

        console.log(`Transfer ready: ${transferAmountTAO} TAO`);

        // Execute the transfer
        console.log('Executing transfer...');
        const tx = await distributor.executeTransfer({
            gasLimit: 200000 // Adjust as needed
        });

        console.log(`Transaction submitted: ${tx.hash}`);

        // Wait for confirmation
        const receipt = await tx.wait();
        console.log(`Transaction confirmed in block ${receipt.blockNumber}`);

        // Parse events
        const transferEvent = receipt.logs.find(log => {
            try {
                const parsed = distributor.interface.parseLog(log);
                return parsed.name === 'StakeTransferred';
            } catch {
                return false;
            }
        });

        if (transferEvent) {
            const parsed = distributor.interface.parseLog(transferEvent);
            const amount = ethers.formatUnits(parsed.args.amount, 9);
            const newBalance = ethers.formatUnits(parsed.args.newBalance, 9);
            console.log(`✅ Transferred ${amount} TAO. New balance: ${newBalance} TAO`);
        }

    } catch (error) {
        console.error('Error executing transfer:', error.message);

        // Check if it was just a "too soon" error
        if (error.message.includes('Too soon')) {
            const blocksLeft = await distributor.blocksUntilNextTransfer();
            console.log(`Transfer not ready. ${blocksLeft} blocks remaining`);
        } else {
            // Re-throw for GitHub Actions to mark as failed
            throw error;
        }
    }
}

main().catch(console.error); 