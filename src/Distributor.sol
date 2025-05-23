// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.3;

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
    uint256 public constant MIN_BLOCK_INTERVAL = 7200; // 1 day = 7200 blocks (12s each)
    uint256 public constant EXISTENTIAL_AMOUNT = 1e9; // 1 TAO (9 decimals)
    uint256 public constant FALLBACK_AMOUNT = 100e9; // 100 TAO
    uint256 public constant BASIS_POINTS = 10000; // 100% = 10000 basis points
    
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
            
            recipients.push(Recipient({
                coldkey: _coldkeys[i],
                proportion: _proportions[i]
            }));
            
            totalProportion += _proportions[i];
        }
        
        require(totalProportion == BASIS_POINTS, "Proportions must sum to 10000");
        emit RecipientsUpdated(recipients.length);
    }
    
    // Owner-only method to set this contract's ss58 public key
    function setThisSs58PublicKey(bytes32 publicKey) external onlyOwner() {
        thisSs58PublicKey = publicKey;
        
        // Initialize balance tracking
        if (publicKey != bytes32(0)) {
            uint256 currentBalance = getStakedBalance();
            previousBalance = currentBalance;
            principalLocked = currentBalance; // All initial balance is considered principal
            
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
        (bool success, ) = ISTAKING_ADDRESS.call{gas: gasleft()}(
            abi.encodeWithSelector(
                staking.transferStake.selector, 
                recipientColdkey, 
                validatorHotkey, 
                netuid, 
                netuid, 
                amount
            )
        );
        require(success, "Transfer stake call failed");
    }
    
    // Detects and records new principal additions automatically
    function updatePrincipal() external {
        require(thisSs58PublicKey != 0, "Public key is not set");
        
        uint256 currentBalance = getStakedBalance();
        
        // If balance increased beyond expected rewards, it's new principal
        if (currentBalance > previousBalance) {
            uint256 increase = currentBalance - previousBalance;
            
            // Assume any large increase (>10% of current principal) is new principal
            // This helps distinguish between rewards and principal additions
            uint256 tenPercentOfPrincipal = principalLocked / 10;
            
            if (increase > tenPercentOfPrincipal || principalLocked == 0) {
                principalLocked += increase;
                previousBalance = currentBalance;
                emit PrincipalDetected(increase, principalLocked);
            }
        }
    }
    
    // Daily reward distribution - transfers only the staking rewards
    function executeTransfer() external {
        require(block.number >= lastTransferBlock + MIN_BLOCK_INTERVAL, "Too soon");
        require(thisSs58PublicKey != 0, "Public key is not set");
        require(principalLocked > 0, "No principal locked");
        require(recipients.length > 0, "No recipients configured");
        
        // Check for new principal first
        uint256 currentBalance = getStakedBalance();
        _detectNewPrincipal(currentBalance);
        
        uint256 transferAmount = _calculateTransferAmount(currentBalance);
        
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
        
        emit StakeTransferred(transferAmount, previousBalance);
    }
    
    function _detectNewPrincipal(uint256 currentBalance) internal {
        if (currentBalance > previousBalance) {
            uint256 increase = currentBalance - previousBalance;
            uint256 tenPercentOfPrincipal = principalLocked / 10;
            
            if (increase > tenPercentOfPrincipal) {
                principalLocked += increase;
                previousBalance = currentBalance;
                emit PrincipalDetected(increase, principalLocked);
            }
        }
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
    
    function _calculateTransferAmount(uint256 currentBalance) internal view returns (uint256) {
        // Only transfer rewards earned since last transfer
        if (currentBalance <= previousBalance) {
            // No rewards earned - transfer fallback amount if we have enough above principal
            uint256 availableAbovePrincipal = currentBalance > principalLocked ? 
                currentBalance - principalLocked : 0;
            
            if (availableAbovePrincipal < FALLBACK_AMOUNT) {
                return availableAbovePrincipal;
            }
            return FALLBACK_AMOUNT;
        }
        
        uint256 rewardsEarned = currentBalance - previousBalance;
        
        // If rewards exceed 1% of principal, cap at fallback amount
        uint256 onePercentOfPrincipal = principalLocked / 100;
        if (rewardsEarned > onePercentOfPrincipal) {
            uint256 availableAbovePrincipal = currentBalance > principalLocked ? 
                currentBalance - principalLocked : 0;
            
            if (availableAbovePrincipal < FALLBACK_AMOUNT) {
                return availableAbovePrincipal;
            }
            return FALLBACK_AMOUNT;
        }
        
        return rewardsEarned;
    }
    
    // View functions
    function getNextTransferAmount() external view returns (uint256) {
        if (thisSs58PublicKey == 0 || principalLocked == 0) return 0;
        uint256 currentBalance = getStakedBalance();
        return _calculateTransferAmount(currentBalance);
    }
    
    function canExecuteTransfer() external view returns (bool) {
        if (block.number < lastTransferBlock + MIN_BLOCK_INTERVAL) return false;
        if (thisSs58PublicKey == 0 || principalLocked == 0) return false;
        if (recipients.length == 0) return false;
        
        uint256 currentBalance = getStakedBalance();
        uint256 transferAmount = _calculateTransferAmount(currentBalance);
        
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
    
    // Owner functions to update recipients (but never touch principal)
    //  TODO: confirm if we want to keep this 
    function updateRecipients(
        bytes32[] memory _coldkeys, 
        uint256[] memory _proportions
    ) external onlyOwner() {
        _setRecipients(_coldkeys, _proportions);
    }
    
    //  TODO: confirm if we want to keep this 
    // Emergency withdraw (if contract receives native tokens, NOT staked tokens)
    function withdraw() external onlyOwner() {
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }
    
    // View the locked principal (can never be withdrawn)
    function getLockedPrincipal() external view returns (uint256) {
        return principalLocked;
    }
}