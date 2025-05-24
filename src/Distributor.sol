// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "./interfaces/IStakingV2.sol";

contract Distributor {
    // Precompile address constant
    address constant ISTAKING_ADDRESS = address(0x808);

    // Precompile instance
    IStakingV2 public staking;

    bytes32 public validatorHotkey; // The validator this contract stakes to
    bytes32 public thisSs58PublicKey; // This contract's SS58 public key
    uint16 public netuid;

    struct Recipient {
        bytes32 coldkey;
        uint256 proportion; // Out of 10000 (basis points)
    }

    Recipient[] public recipients;
    uint256 public totalProportion; // Should always equal 10000

    uint256 public previousBalance;
    uint256 public lastTransferBlock;
    uint256 public principalLocked; // Total principal that can never be touched
    uint256 public lastRewardRate; // Alpha per block from last transfer
    uint256 public lastPaymentAmount; // Last successful payment amount
    uint256 public constant MIN_BLOCK_INTERVAL = 7200; // 1 day = 7200 blocks (12s each)
    uint256 public constant EXISTENTIAL_AMOUNT = 1e9; // 1 TAO (9 decimals)
    uint256 public constant BASIS_POINTS = 10000; // 100% = 10000 basis points
    uint256 public constant RATE_MULTIPLIER_THRESHOLD = 2; // 2x rate increase threshold

    address public owner; // Only for emergency functions, cannot touch principal

    modifier onlyOwner() {
        require(owner == msg.sender, "Caller is not the owner");
        _;
    }

    event StakeTransferred(uint256 totalAmount, uint256 newBalance);
    event RecipientTransfer(bytes32 indexed coldkey, uint256 amount, uint256 proportion);
    event TransferSkipped(string reason, uint256 calculatedAmount);
    event PrincipalDetected(uint256 amount, uint256 totalPrincipal);
    event RecipientsUpdated(uint256 recipientCount);
    event ValidatorHotkeyChanged(bytes32 oldHotkey, bytes32 newHotkey);

    constructor(
        address _owner,
        bytes32 _validatorHotkey,
        uint16 _netuid,
        bytes32[] memory _recipientColdkeys,
        uint256[] memory _proportions
    ) {
        require(_owner != address(0), "Invalid owner address");
        require(_validatorHotkey != 0, "Invalid validator hotkey");
        require(_recipientColdkeys.length == _proportions.length, "Array length mismatch");
        require(_recipientColdkeys.length > 0, "No recipients provided");

        owner = _owner;
        validatorHotkey = _validatorHotkey;
        netuid = _netuid;
        lastTransferBlock = block.number;

        // Set up recipients
        _setRecipients(_recipientColdkeys, _proportions);

        staking = IStakingV2(ISTAKING_ADDRESS);
    }

    function _setRecipients(bytes32[] memory _coldkeys, uint256[] memory _proportions) internal {
        // Clear existing recipients
        delete recipients;
        totalProportion = 0;

        // Add new recipients
        for (uint256 i = 0; i < _coldkeys.length; i++) {
            require(_coldkeys[i] != bytes32(0), "Invalid coldkey");
            require(_proportions[i] > 0, "Proportion must be > 0");

            recipients.push(Recipient({coldkey: _coldkeys[i], proportion: _proportions[i]}));

            totalProportion += _proportions[i];
        }

        require(totalProportion == BASIS_POINTS, "Proportions must sum to 10000");
        emit RecipientsUpdated(recipients.length);
    }

    // Owner-only method to change validator hotkey
    function changeValidatorHotkey(bytes32 newHotkey) external onlyOwner {
        require(newHotkey != bytes32(0), "Invalid hotkey");
        require(newHotkey != validatorHotkey, "Same hotkey");
        
        bytes32 oldHotkey = validatorHotkey;
        validatorHotkey = newHotkey;
        
        emit ValidatorHotkeyChanged(oldHotkey, newHotkey);
    }

    // Owner-only method to set this contract's ss58 public key
    function setThisSs58PublicKey(bytes32 publicKey) external onlyOwner {
        thisSs58PublicKey = publicKey;

        // Initialize balance tracking
        if (publicKey != bytes32(0)) {
            uint256 currentBalance = getStakedBalance();
            previousBalance = currentBalance;
            principalLocked = currentBalance; // All initial balance is considered principal
            lastRewardRate = 0; // No previous rate on first setup
            lastPaymentAmount = 0; // No previous payment

            if (currentBalance > 0) {
                emit PrincipalDetected(currentBalance, principalLocked);
            }
        }
    }

    function getStakedBalance() public view returns (uint256) {
        require(thisSs58PublicKey != 0, "Public key is not set");
        (bool success, bytes memory resultData) = ISTAKING_ADDRESS.staticcall(
            abi.encodeWithSelector(staking.getStake.selector, validatorHotkey, thisSs58PublicKey, netuid)
        );
        require(success, "Failed to read getStake");
        return abi.decode(resultData, (uint256));
    }

    function _transferStake(bytes32 recipientColdkey, uint256 amount) private {
        (bool success,) = ISTAKING_ADDRESS.call{gas: gasleft()}(
            abi.encodeWithSelector(
                staking.transferStake.selector, recipientColdkey, validatorHotkey, netuid, netuid, amount
            )
        );
        require(success, "Transfer stake call failed");
    }

    // Daily reward distribution - transfers only the staking rewards
    function executeTransfer() external {
        require(block.number >= lastTransferBlock + MIN_BLOCK_INTERVAL, "Too soon");
        require(thisSs58PublicKey != 0, "Public key is not set");
        require(principalLocked > 0, "No principal locked");
        require(recipients.length > 0, "No recipients configured");

        uint256 currentBalance = getStakedBalance();
        uint256 blocksPassed = block.number - lastTransferBlock;
        
        uint256 transferAmount = _calculateTransferAmountWithRateAnalysis(currentBalance, blocksPassed);

        if (transferAmount < EXISTENTIAL_AMOUNT) {
            emit TransferSkipped("Below existential amount", transferAmount);
            return;
        }

        // CRITICAL: Ensure we never touch the principal
        uint256 balanceAfterTransfer = currentBalance - transferAmount;
        require(balanceAfterTransfer >= principalLocked, "Cannot touch principal");

        // Distribute to all recipients proportionally
        _distributeToRecipients(transferAmount);

        // Update state
        previousBalance = balanceAfterTransfer;
        lastTransferBlock = block.number;
        lastPaymentAmount = transferAmount;

        emit StakeTransferred(transferAmount, previousBalance);
    }

    function _calculateTransferAmountWithRateAnalysis(uint256 currentBalance, uint256 blocksPassed) internal returns (uint256) {
        // Handle first execution case
        if (lastRewardRate == 0 && lastPaymentAmount == 0) {
            // First execution - any balance above principal is rewards
            uint256 availableRewards = currentBalance > principalLocked ? currentBalance - principalLocked : 0;
            if (availableRewards > 0 && blocksPassed > 0) {
                lastRewardRate = (availableRewards * 1e18) / blocksPassed; // Store with precision
            }
            return availableRewards;
        }

        // Calculate delta and current rate
        uint256 deltaBalance = currentBalance > previousBalance ? currentBalance - previousBalance : 0;
        
        if (deltaBalance == 0) {
            // No rewards earned - use last payment amount if we have enough above principal
            uint256 availableAbovePrincipal = currentBalance > principalLocked ? currentBalance - principalLocked : 0;
            return availableAbovePrincipal >= lastPaymentAmount ? lastPaymentAmount : availableAbovePrincipal;
        }

        if (blocksPassed == 0) {
            // Edge case: same block execution
            return deltaBalance;
        }

        uint256 currentRate = (deltaBalance * 1e18) / blocksPassed; // Store with precision

        // Check if rate more than doubled (indicating principal addition)
        if (lastRewardRate > 0 && currentRate > lastRewardRate * RATE_MULTIPLIER_THRESHOLD) {
            // Likely principal addition detected
            principalLocked += deltaBalance;
            previousBalance = currentBalance;
            emit PrincipalDetected(deltaBalance, principalLocked);
            
            // Use last payment amount instead of the inflated delta
            uint256 availableAbovePrincipal = currentBalance > principalLocked ? currentBalance - principalLocked : 0;
            return availableAbovePrincipal >= lastPaymentAmount ? lastPaymentAmount : availableAbovePrincipal;
        }

        // Normal rewards - update rate and return delta
        lastRewardRate = currentRate;
        return deltaBalance;
    }

    function _distributeToRecipients(uint256 totalAmount) internal {
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 recipientAmount = (totalAmount * recipients[i].proportion) / BASIS_POINTS;

            if (recipientAmount >= EXISTENTIAL_AMOUNT) {
                _transferStake(recipients[i].coldkey, recipientAmount);
                emit RecipientTransfer(recipients[i].coldkey, recipientAmount, recipients[i].proportion);
            }
        }
    }

    // View functions
    function getNextTransferAmount() external view returns (uint256) {
        if (thisSs58PublicKey == 0 || principalLocked == 0) return 0;
        uint256 currentBalance = getStakedBalance();
        uint256 blocksPassed = block.number - lastTransferBlock;
        
        // Simplified view version without state updates
        if (lastRewardRate == 0 && lastPaymentAmount == 0) {
            return currentBalance > principalLocked ? currentBalance - principalLocked : 0;
        }

        uint256 deltaBalance = currentBalance > previousBalance ? currentBalance - previousBalance : 0;
        
        if (deltaBalance == 0) {
            uint256 availableAbovePrincipal = currentBalance > principalLocked ? currentBalance - principalLocked : 0;
            return availableAbovePrincipal >= lastPaymentAmount ? lastPaymentAmount : availableAbovePrincipal;
        }

        if (blocksPassed == 0) return deltaBalance;

        uint256 currentRate = (deltaBalance * 1e18) / blocksPassed;
        
        if (lastRewardRate > 0 && currentRate > lastRewardRate * RATE_MULTIPLIER_THRESHOLD) {
            uint256 availableAbovePrincipal = currentBalance > principalLocked ? currentBalance - principalLocked : 0;
            return availableAbovePrincipal >= lastPaymentAmount ? lastPaymentAmount : availableAbovePrincipal;
        }

        return deltaBalance;
    }

    function canExecuteTransfer() external view returns (bool) {
        if (block.number < lastTransferBlock + MIN_BLOCK_INTERVAL) return false;
        if (thisSs58PublicKey == 0 || principalLocked == 0) return false;
        if (recipients.length == 0) return false;

        uint256 currentBalance = getStakedBalance();
        uint256 blocksPassed = block.number - lastTransferBlock;
        
        // Use view version of calculation
        uint256 transferAmount;
        if (lastRewardRate == 0 && lastPaymentAmount == 0) {
            transferAmount = currentBalance > principalLocked ? currentBalance - principalLocked : 0;
        } else {
            uint256 deltaBalance = currentBalance > previousBalance ? currentBalance - previousBalance : 0;
            
            if (deltaBalance == 0) {
                uint256 availableAbovePrincipal = currentBalance > principalLocked ? currentBalance - principalLocked : 0;
                transferAmount = availableAbovePrincipal >= lastPaymentAmount ? lastPaymentAmount : availableAbovePrincipal;
            } else if (blocksPassed == 0) {
                transferAmount = deltaBalance;
            } else {
                uint256 currentRate = (deltaBalance * 1e18) / blocksPassed;
                
                if (lastRewardRate > 0 && currentRate > lastRewardRate * RATE_MULTIPLIER_THRESHOLD) {
                    uint256 availableAbovePrincipal = currentBalance > principalLocked ? currentBalance - principalLocked : 0;
                    transferAmount = availableAbovePrincipal >= lastPaymentAmount ? lastPaymentAmount : availableAbovePrincipal;
                } else {
                    transferAmount = deltaBalance;
                }
            }
        }

        return transferAmount >= EXISTENTIAL_AMOUNT;
    }

    function blocksUntilNextTransfer() external view returns (uint256) {
        uint256 nextBlock = lastTransferBlock + MIN_BLOCK_INTERVAL;
        if (block.number >= nextBlock) return 0;
        return nextBlock - block.number;
    }

    function getAvailableRewards() external view returns (uint256) {
        uint256 currentBalance = getStakedBalance();
        if (currentBalance <= principalLocked) return 0;
        return currentBalance - principalLocked;
    }

    function getRecipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function getRecipient(uint256 index) external view returns (bytes32 coldkey, uint256 proportion) {
        require(index < recipients.length, "Index out of bounds");
        Recipient memory recipient = recipients[index];
        return (recipient.coldkey, recipient.proportion);
    }

    // View the locked principal (can never be withdrawn)
    function getLockedPrincipal() external view returns (uint256) {
        return principalLocked;
    }

    // View current reward rate (alpha per block with 1e18 precision)
    function getCurrentRewardRate() external view returns (uint256) {
        return lastRewardRate;
    }

    // View last payment amount
    function getLastPaymentAmount() external view returns (uint256) {
        return lastPaymentAmount;
    }
}
