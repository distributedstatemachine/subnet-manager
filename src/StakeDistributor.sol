// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IStakingV2.sol";

/**
 * @title StakeDistributor
 * @dev Manages the configuration and calculation logic for APY distribution
 * This contract does not hold funds or execute state-changing Subtensor operations directly
 */
contract StakeDistributor {
    address public immutable iStakingV2Precompile;
    address public owner; // The MultiSigWalletWithVeto contract address

    bytes32 public multisigColdkeyBytes32;
    bytes32 public associatedHotkeyBytes32;
    uint16 public netuid;

    struct DistributionTarget {
        bytes32 coldkey;
        uint16 ratioPermille; // e.g., 500 for 50%
    }
    DistributionTarget[] public distributionTargets;
    uint16 public totalRatioPermille; // Should sum to 1000 if properly configured

    uint256 public lastKnownStakeBalanceRao;
    uint256 public lastDistributionTimestamp;
    uint256 public minDistributionIntervalSeconds;

    struct TransferOperation {
        bytes32 destinationColdkey;
        uint256 amountRao;
    }

    uint256 public lastDistribution;          // unix-time of the last run
    uint256 public immutable distributionInterval;

    // --- Events ---
    event OwnerUpdated(address indexed newOwner);
    event Initialized(
        bytes32 indexed coldkey,
        bytes32 indexed hotkey,
        uint16 indexed netuid,
        uint256 initialStakeRao,
        uint256 minInterval
    );
    event DistributionTargetsUpdated(DistributionTarget[] newTargets, uint16 newTotalRatio);
    event ManualStakeChangeReported(int256 amountChangeRao, uint256 newBalanceRao);
    event ApyDistributed(
        uint256 totalDistributedRao,
        uint256 newStakeBalanceRao,
        uint256 distributionTimestamp
    );
    event MinIntervalUpdated(uint256 newInterval);

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "StakeDistributor: Caller is not the owner");
        _;
    }

    /**
     * @dev Constructor to initialize the contract with the StakingV2 precompile address and initial owner
     * @param _stakingV2Address Address of the StakingV2 precompile
     * @param _initialOwner Address of the initial owner (MultiSigWalletWithVeto)
     */
    constructor(address _stakingV2Address, address _initialOwner, uint256 _interval) {
        require(_stakingV2Address != address(0), "SD: Invalid stakingV2 address");
        require(_initialOwner != address(0), "SD: Invalid owner address");
        require(_interval > 0, "SD: interval 0");
        iStakingV2Precompile = _stakingV2Address;
        owner = _initialOwner;
        emit OwnerUpdated(_initialOwner);
        distributionInterval = _interval;
        lastDistribution = block.timestamp;   // prevents premature run
    }

    /**
     * @dev Initialize the contract with the subnet owner's details and distribution configuration
     * @param _multisigColdkey The coldkey of the MultiSig wallet (subnet owner)
     * @param _associatedHotkey The hotkey associated with the coldkey
     * @param _netuid The network ID
     * @param _initialTargets Initial distribution targets with their ratios
     * @param _initialLastKnownStakeRao Initial stake balance of the coldkey
     * @param _minIntervalSeconds Minimum interval between distributions
     */
    function initialize(
        bytes32 _multisigColdkey,
        bytes32 _associatedHotkey,
        uint16 _netuid,
        DistributionTarget[] memory _initialTargets,
        uint256 _initialLastKnownStakeRao,
        uint256 _minIntervalSeconds
    ) external onlyOwner {
        require(multisigColdkeyBytes32 == bytes32(0), "SD: Already initialized");
        require(_multisigColdkey != bytes32(0), "SD: Multisig coldkey required");
        require(_associatedHotkey != bytes32(0), "SD: Associated hotkey required");
        require(_minIntervalSeconds > 0, "SD: Min interval must be positive");

        multisigColdkeyBytes32 = _multisigColdkey;
        associatedHotkeyBytes32 = _associatedHotkey;
        netuid = _netuid;
        lastKnownStakeBalanceRao = _initialLastKnownStakeRao;
        minDistributionIntervalSeconds = _minIntervalSeconds;
        lastDistributionTimestamp = block.timestamp; // Set initial distribution timestamp
        
        _updateDistributionTargetsInternal(_initialTargets); // Internal helper

        emit Initialized(
            _multisigColdkey,
            _associatedHotkey,
            _netuid,
            _initialLastKnownStakeRao,
            _minIntervalSeconds
        );
    }

    /**
     * @dev Update the distribution targets and their ratios
     * @param _newTargets New distribution targets with their ratios
     */
    function updateDistributionTargets(DistributionTarget[] memory _newTargets) external onlyOwner {
        _updateDistributionTargetsInternal(_newTargets);
    }

    /**
     * @dev Internal function to update distribution targets
     * @param _newTargets New distribution targets with their ratios
     */
    function _updateDistributionTargetsInternal(DistributionTarget[] memory _newTargets) internal {
        require(_newTargets.length > 0, "SD: Empty targets");
        
        // Clear existing targets
        delete distributionTargets;
        
        // Reset total ratio
        totalRatioPermille = 0;
        
        // Add new targets
        for (uint256 i = 0; i < _newTargets.length; i++) {
            require(_newTargets[i].coldkey != bytes32(0), "SD: Invalid coldkey");
            require(_newTargets[i].ratioPermille > 0, "SD: Invalid ratio");
            
            distributionTargets.push(_newTargets[i]);
            totalRatioPermille += _newTargets[i].ratioPermille;
        }
        
        require(totalRatioPermille <= 1000, "SD: Total ratio cannot exceed 1000 permille");
        
        emit DistributionTargetsUpdated(_newTargets, totalRatioPermille);
    }
    
    /**
     * @dev Update the minimum interval between distributions
     * @param _newIntervalSeconds New minimum interval in seconds
     */
    function updateMinDistributionInterval(uint256 _newIntervalSeconds) external onlyOwner {
        require(_newIntervalSeconds > 0, "SD: Interval must be positive");
        minDistributionIntervalSeconds = _newIntervalSeconds;
        emit MinIntervalUpdated(_newIntervalSeconds);
    }

    /**
     * @dev Report a manual stake change (not related to APY distribution)
     * @param _amountChangeRao Amount of stake change (positive for increase, negative for decrease)
     */
    function reportManualStakeChange(int256 _amountChangeRao) external onlyOwner {
        if (_amountChangeRao > 0) {
            lastKnownStakeBalanceRao += uint256(_amountChangeRao);
        } else {
            uint256 reduction = uint256(-_amountChangeRao);
            if (lastKnownStakeBalanceRao >= reduction) {
                lastKnownStakeBalanceRao -= reduction;
            } else {
                // This implies more was removed than known, chain state might have diverged
                // or a previous report was missed. Setting to 0 is a safe fallback.
                lastKnownStakeBalanceRao = 0;
            }
        }
        emit ManualStakeChangeReported(_amountChangeRao, lastKnownStakeBalanceRao);
    }

    /**
     * @dev Calculate the APY distribution based on current stake and distribution targets
     * @return operations Array of transfer operations to execute
     * @return newExpectedStakeBalanceRao Expected stake balance after distribution
     */
    function calculateApyDistribution()
        external
        view
        returns (TransferOperation[] memory operations, uint256 newExpectedStakeBalanceRao)
    {
        if (multisigColdkeyBytes32 == bytes32(0)) { // Not initialized
            return (new TransferOperation[](0), 0);
        }
        if (lastDistributionTimestamp > 0 && 
            block.timestamp < lastDistributionTimestamp + minDistributionIntervalSeconds) {
            // Not enough time has passed, return empty array
            return (new TransferOperation[](0), lastKnownStakeBalanceRao);
        }

        uint256 currentStakeRao = IStakingV2(iStakingV2Precompile).getStake(
            associatedHotkeyBytes32,
            multisigColdkeyBytes32,
            netuid
        );

        if (currentStakeRao <= lastKnownStakeBalanceRao) {
            // No APY earned or stake decreased unexpectedly (manual removal not reported?)
            // Return empty operations and the current actual stake
            return (new TransferOperation[](0), currentStakeRao);
        }

        uint256 apyEarnedRao = currentStakeRao - lastKnownStakeBalanceRao;
        uint256 totalToDistributeThisCycle = 0;
        
        // Count non-zero operations first for correct array sizing
        uint256 opsCount = 0;
        for(uint i = 0; i < distributionTargets.length; i++) {
            if (apyEarnedRao > 0 && distributionTargets[i].ratioPermille > 0) {
                 uint256 amountForTarget = (apyEarnedRao * distributionTargets[i].ratioPermille) / 1000;
                 if (amountForTarget > 0) {
                    opsCount++;
                 }
            }
        }
        
        TransferOperation[] memory ops = new TransferOperation[](opsCount);
        uint256 currentOpIndex = 0;

        for (uint256 i = 0; i < distributionTargets.length; i++) {
            if (apyEarnedRao == 0 || distributionTargets[i].ratioPermille == 0) continue;

            uint256 amountForTarget = (apyEarnedRao * distributionTargets[i].ratioPermille) / 1000;
            if (amountForTarget > 0) {
                // Ensure we don't try to distribute more than available due to dust accumulation from multiple targets
                if (totalToDistributeThisCycle + amountForTarget > apyEarnedRao) {
                    amountForTarget = apyEarnedRao - totalToDistributeThisCycle;
                }
                if (amountForTarget > 0 && currentOpIndex < opsCount) { // Check currentOpIndex boundary
                    ops[currentOpIndex] = TransferOperation(distributionTargets[i].coldkey, amountForTarget);
                    totalToDistributeThisCycle += amountForTarget;
                    currentOpIndex++;
                }
            }
            if (totalToDistributeThisCycle >= apyEarnedRao) break; // Stop if all APY is allocated
        }
        
        newExpectedStakeBalanceRao = currentStakeRao - totalToDistributeThisCycle;
        return (ops, newExpectedStakeBalanceRao);
    }

    /**
     * @dev Confirm that APY distribution has been executed
     * @param _totalDistributedRao Total amount of stake distributed
     * @param _actualStakeAfterDistributionRao Actual stake balance after distribution
     */
    function confirmApyDistributionExecuted(
        uint256 _totalDistributedRao, // Actual amount confirmed by keeper to have been sent
        uint256 _actualStakeAfterDistributionRao // Actual stake of multisig coldkey confirmed by keeper
    ) external onlyOwner {
        // It's possible _totalDistributedRao is 0 if no APY was found or ratios led to 0 for all.
        // The _actualStakeAfterDistributionRao is the most important for resetting the baseline.
        
        lastKnownStakeBalanceRao = _actualStakeAfterDistributionRao;
        lastDistributionTimestamp = block.timestamp; // Set only if a distribution attempt was made.
                                                 // Could also be `if (_totalDistributedRao > 0)`
        emit ApyDistributed(_totalDistributedRao, lastKnownStakeBalanceRao, lastDistributionTimestamp);
    }
    
    /**
     * @dev Transfer ownership of the contract
     * @param _newOwner New owner address
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "SD: New owner cannot be zero address");
        owner = _newOwner;
        emit OwnerUpdated(_newOwner);
    }

    // --- View Functions ---
    
    /**
     * @dev Get all distribution targets
     * @return Array of distribution targets
     */
    function getDistributionTargets() external view returns (DistributionTarget[] memory) {
        return distributionTargets;
    }

    /**
     * @dev Get the full configuration of the contract
     * @return ownerAddress Address of the owner
     * @return coldkey Coldkey of the MultiSig wallet
     * @return hotkey Associated hotkey
     * @return currentNetuid Network ID
     * @return knownStakeRao Last known stake balance
     * @return lastDistTime Last distribution timestamp
     * @return minDistInterval Minimum distribution interval
     * @return currentTotalRatio Total ratio of distribution targets
     */
    function getConfig() external view returns (
        address ownerAddress,
        bytes32 coldkey,
        bytes32 hotkey,
        uint16 currentNetuid,
        uint256 knownStakeRao,
        uint256 lastDistTime,
        uint256 minDistInterval,
        uint16 currentTotalRatio
    ) {
        return (
            owner,
            multisigColdkeyBytes32,
            associatedHotkeyBytes32,
            netuid,
            lastKnownStakeBalanceRao,
            lastDistributionTimestamp,
            minDistributionIntervalSeconds,
            totalRatioPermille
        );
    }

    function nextDistributionTime() external view returns (uint256) {
        return lastDistribution + distributionInterval;
    }

    function canDistribute() public view returns (bool) {
        return block.timestamp >= lastDistribution + distributionInterval;
    }

    function _enforceInterval() internal view {
        require(
            block.timestamp >= lastDistribution + distributionInterval,
            "SD: interval not reached"
        );
    }

    function _distribute() internal {
        // Implementation of the distribute function
        lastDistribution = block.timestamp;
    }
} 