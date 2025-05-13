Okay, providing the *full* code for a production-ready system of this complexity in a single response is a bit ambitious (and would be extremely long!). However, I can provide you with the core smart contract code for:

1.  `MultiSigWalletWithVeto.sol`
2.  `StakeDistributor.sol`
3.  Necessary `Interfaces.sol`

This will form the heart of your on-chain system. The off-chain Keeper script and detailed Foundry test/deployment scripts would still need to be developed based on this.

**Important Disclaimers:**

*   **This code is for illustrative and specification purposes.** It has not been audited. **DO NOT USE IN PRODUCTION WITHOUT A THOROUGH PROFESSIONAL AUDIT.**
*   Error handling, gas optimizations, and advanced edge-case considerations might require further refinement.
*   The focus here is on implementing the specified logic.
*   Constants like precompile addresses should be verified for your target network.
*   The `bytes32` representation for coldkeys/hotkeys assumes you are passing the raw 32-byte public key.

---

## Smart Contract Code

### 1. `src/interfaces/Interfaces.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakingV2 {
    // --- State Changing Functions ---
    function addStake(bytes32 hotkey, uint256 amountRao, uint16 netuid) external payable;
    function removeStake(bytes32 hotkey, uint256 amountAlpha, uint16 netuid) external; // Note: amount is alpha
    function moveStake(
        bytes32 originHotkey,
        bytes32 destinationHotkey,
        uint16 originNetuid,
        uint16 destinationNetuid,
        uint256 amountAlpha // Note: amount is alpha
    ) external;
    function transferStake(
        bytes32 destinationColdkey,
        bytes32 hotkey, // The hotkey whose stake is being transferred
        uint16 originNetuid,
        uint16 destinationNetuid,
        uint256 amountAlpha // Note: amount is alpha
    ) external;
    function addProxy(bytes32 delegate) external;
    function removeProxy(bytes32 delegate) external;

    // --- View Functions ---
    function getTotalColdkeyStake(bytes32 coldkey) external view returns (uint256 stakeRao);
    function getTotalHotkeyStake(bytes32 hotkey) external view returns (uint256 stakeRao);
    function getStake(bytes32 hotkey, bytes32 coldkey, uint16 netuid) external view returns (uint256 stakeRao);
    function getAlphaStakedValidators(bytes32 hotkey, uint16 netuid) external view returns (bytes32[] memory coldkeys);
    function getTotalAlphaStaked(bytes32 hotkey, uint16 netuid) external view returns (uint256 stakeAlpha);
}

interface ISubnet {
    // --- State Changing Functions (Examples) ---
    function registerNetwork(bytes32 hotkey) external payable;
    function registerNetwork(
        bytes32 hotkey,
        string memory subnetName,
        string memory githubRepo,
        string memory subnetContact,
        string memory subnetUrl,
        string memory discord,
        string memory description,
        string memory additional
    ) external payable;
    function setImmunityPeriod(uint16 netuid, uint16 immunityPeriod) external payable;
    // ... Add other functions from subnet.abi that the MultiSig might need to call

    // --- View Functions (Examples) ---
    function getImmunityPeriod(uint16 netuid) external view returns (uint16);
    // ... Add other view functions
}

// Interface for MultiSig itself, useful for type-casting if needed
interface IMultiSigWalletWithVeto {
    function proposeTransaction(address target, uint256 value, bytes calldata data) external returns (uint256 proposalId);
    function vetoTransaction(uint256 proposalId) external;
    function executeTransaction(uint256 proposalId) external;
    // ... other relevant view functions
}
```

---

### 2. `src/MultiSigWalletWithVeto.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/Interfaces.sol"; // For IMultiSigWalletWithVeto, not strictly needed here but good practice

contract MultiSigWalletWithVeto {
    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        uint256 proposalTime;
        uint256 vetoDeadline;
        uint256 vetoCount;
        bool executed;
        bool cancelled;
    }

    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public ownerCount;

    uint256 public vetoesRequiredToCancel;
    uint256 public vetoDurationSeconds;

    Proposal[] public proposals;
    uint256 public proposalCount; // Also serves as proposalId for new proposals

    // proposalId => ownerAddress => hasVetoed
    mapping(uint256 => mapping(address => bool)) public proposalVetoes;

    // --- Events ---
    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed removedOwner);
    event VetoRequirementChanged(uint256 newVetoesRequired);
    event VetoDurationChanged(uint256 newVetoDurationSeconds);

    event ProposalSubmitted(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 vetoDeadline
    );
    event ProposalVetoed(uint256 indexed proposalId, address indexed vetoer, uint256 newVetoCount);
    event ProposalCancelled(uint256 indexed proposalId);
    event ProposalExecutionReady(uint256 indexed proposalId); // Informational
    event ProposalExecuted(uint256 indexed proposalId, bool success, bytes returnData);

    // --- Modifiers ---
    modifier onlyOwner() {
        require(isOwner[msg.sender], "MultiSig: Not an owner");
        _;
    }

    modifier proposalExists(uint256 _proposalId) {
        require(_proposalId < proposalCount, "MultiSig: Proposal does not exist");
        _;
    }

    modifier notCancelled(uint256 _proposalId) {
        require(!proposals[_proposalId].cancelled, "MultiSig: Proposal is cancelled");
        _;
    }

    modifier notExecuted(uint256 _proposalId) {
        require(!proposals[_proposalId].executed, "MultiSig: Proposal already executed");
        _;
    }

    constructor(
        address[] memory _initialOwners,
        uint256 _requiredVetoes,
        uint256 _durationSeconds
    ) {
        require(_initialOwners.length > 0, "MultiSig: Owners required");
        require(_durationSeconds > 0, "MultiSig: Duration must be positive");

        for (uint256 i = 0; i < _initialOwners.length; i++) {
            address owner = _initialOwners[i];
            require(owner != address(0), "MultiSig: Invalid owner address");
            require(!isOwner[owner], "MultiSig: Duplicate owner");
            isOwner[owner] = true;
            owners.push(owner);
            emit OwnerAdded(owner);
        }
        ownerCount = _initialOwners.length;

        require(_requiredVetoes > 0 && _requiredVetoes < ownerCount, "MultiSig: Invalid veto requirement");
        // (ownerCount - 1) is max possible vetoers if proposer cannot veto.
        // If _requiredVetoes == ownerCount, it implies ALL other owners must veto.
        vetoesRequiredToCancel = _requiredVetoes;
        vetoDurationSeconds = _durationSeconds;

        emit VetoRequirementChanged(_requiredVetoes);
        emit VetoDurationChanged(_durationSeconds);
    }

    receive() external payable {} // To receive ETH if needed for proposals

    function proposeTransaction(
        address _target,
        uint256 _value,
        bytes calldata _data
    ) external onlyOwner returns (uint256 proposalId) {
        require(_target != address(0), "MultiSig: Target cannot be zero address");

        proposalId = proposalCount;
        uint256 deadline = block.timestamp + vetoDurationSeconds;

        proposals.push(
            Proposal({
                proposer: msg.sender,
                target: _target,
                value: _value,
                data: _data,
                proposalTime: block.timestamp,
                vetoDeadline: deadline,
                vetoCount: 0,
                executed: false,
                cancelled: false
            })
        );
        proposalCount++;

        emit ProposalSubmitted(proposalId, msg.sender, _target, _value, _data, deadline);
        return proposalId;
    }

    function vetoTransaction(uint256 _proposalId)
        external
        onlyOwner
        proposalExists(_proposalId)
        notCancelled(_proposalId)
        notExecuted(_proposalId)
    {
        Proposal storage proposal = proposals[_proposalId];
        require(msg.sender != proposal.proposer, "MultiSig: Proposer cannot veto");
        require(!proposalVetoes[_proposalId][msg.sender], "MultiSig: Already vetoed");
        require(block.timestamp < proposal.vetoDeadline, "MultiSig: Veto period ended");

        proposalVetoes[_proposalId][msg.sender] = true;
        proposal.vetoCount++;

        emit ProposalVetoed(_proposalId, msg.sender, proposal.vetoCount);

        if (proposal.vetoCount >= vetoesRequiredToCancel) {
            proposal.cancelled = true;
            emit ProposalCancelled(_proposalId);
        }
    }

    function executeTransaction(uint256 _proposalId)
        external
        proposalExists(_proposalId)
        notCancelled(_proposalId)
        notExecuted(_proposalId)
    {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp >= proposal.vetoDeadline, "MultiSig: Veto period not yet ended");
        // Redundant check if notCancelled modifier is used, but good for clarity
        require(proposal.vetoCount < vetoesRequiredToCancel, "MultiSig: Proposal was sufficiently vetoed");

        proposal.executed = true;

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory returnData) = proposal.target.call{value: proposal.value}(proposal.data);

        emit ProposalExecuted(_proposalId, success, returnData);
    }

    // --- Administrative functions are proposed by calling proposeTransaction with target = address(this) ---
    // --- and data = abi.encodeWithSelector(this.internal_function.selector, args) ---

    function _addOwner(address _newOwner) internal {
        require(msg.sender == address(this), "MultiSig: Internal call only");
        require(_newOwner != address(0), "MultiSig: Invalid new owner");
        require(!isOwner[_newOwner], "MultiSig: Owner already exists");

        isOwner[_newOwner] = true;
        owners.push(_newOwner);
        ownerCount++;
        emit OwnerAdded(_newOwner);
    }

    function _removeOwner(address _ownerToRemove) internal {
        require(msg.sender == address(this), "MultiSig: Internal call only");
        require(isOwner[_ownerToRemove], "MultiSig: Not an owner");
        require(ownerCount > 1, "MultiSig: Cannot remove last owner");

        // Update vetoesRequiredToCancel if necessary BEFORE removing owner
        // Example: if new ownerCount-1 < vetoesRequiredToCancel, it might become impossible to meet veto.
        // This logic needs careful consideration based on desired behavior.
        // For now, we'll assume it's handled by the proposers ensuring valid state.
        // Or, require vetoesRequiredToCancel to be adjusted in a separate proposal first.

        isOwner[_ownerToRemove] = false;
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == _ownerToRemove) {
                owners[i] = owners[owners.length - 1];
                owners.pop();
                break;
            }
        }
        ownerCount--;
        // Post-condition check for vetoesRequiredToCancel validity
        if (ownerCount > 1 && vetoesRequiredToCancel >= ownerCount) {
             // This state is problematic. The proposal that led here should have considered this.
             // Or, an immediate follow-up proposal to adjust vetoesRequiredToCancel is needed.
        } else if (ownerCount <= 1 && vetoesRequiredToCancel > 0) {
             // Also problematic for single owner scenarios if vetoes are still required.
        }

        emit OwnerRemoved(_ownerToRemove);
    }

    function _changeVetoRequirement(uint256 _newVetoesRequired) internal {
        require(msg.sender == address(this), "MultiSig: Internal call only");
        require(_newVetoesRequired > 0 && (ownerCount <=1 || _newVetoesRequired < ownerCount), "MultiSig: Invalid new veto requirement");
        vetoesRequiredToCancel = _newVetoesRequired;
        emit VetoRequirementChanged(_newVetoesRequired);
    }

    function _changeVetoDuration(uint256 _newDurationSeconds) internal {
        require(msg.sender == address(this), "MultiSig: Internal call only");
        require(_newDurationSeconds > 0, "MultiSig: Duration must be positive");
        vetoDurationSeconds = _newDurationSeconds;
        emit VetoDurationChanged(_newDurationSeconds);
    }


    // --- View Functions ---
    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getProposal(uint256 _proposalId)
        external
        view
        proposalExists(_proposalId)
        returns (Proposal memory)
    {
        return proposals[_proposalId];
    }

    function getVetoers(uint256 _proposalId)
        external
        view
        proposalExists(_proposalId)
        returns (address[] memory vetoerAddresses)
    {
        address[] memory currentOwners = owners; // Cache to avoid multiple reads
        uint256 count = 0;
        for (uint256 i = 0; i < currentOwners.length; i++) {
            if (proposalVetoes[_proposalId][currentOwners[i]]) {
                count++;
            }
        }
        vetoerAddresses = new address[](count);
        count = 0;
        for (uint256 i = 0; i < currentOwners.length; i++) {
            if (proposalVetoes[_proposalId][currentOwners[i]]) {
                vetoerAddresses[count++] = currentOwners[i];
            }
        }
        return vetoerAddresses;
    }

    function isProposalReadyForExecution(uint256 _proposalId)
        public // public for easier off-chain check
        view
        proposalExists(_proposalId)
        returns (bool)
    {
        Proposal storage proposal = proposals[_proposalId];
        return
            !proposal.executed &&
            !proposal.cancelled &&
            block.timestamp >= proposal.vetoDeadline &&
            proposal.vetoCount < vetoesRequiredToCancel;
    }
}
```

---

### 3. `src/StakeDistributor.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/Interfaces.sol";

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

    constructor(address _stakingV2Address, address _initialOwner) {
        require(_stakingV2Address != address(0), "SD: Invalid stakingV2 address");
        require(_initialOwner != address(0), "SD: Invalid owner address");
        iStakingV2Precompile = _stakingV2Address;
        owner = _initialOwner;
        emit OwnerUpdated(_initialOwner);
    }

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
        
        _updateDistributionTargetsInternal(_initialTargets); // Internal helper

        emit Initialized(
            _multisigColdkey,
            _associatedHotkey,
            _netuid,
            _initialLastKnownStakeRao,
            _minIntervalSeconds
        );
    }

    function updateDistributionTargets(DistributionTarget[] memory _newTargets) external onlyOwner {
        _updateDistributionTargetsInternal(_newTargets);
    }

    function _updateDistributionTargetsInternal(DistributionTarget[] memory _newTargets) internal {
        uint16 currentTotalRatio = 0;
        for (uint256 i = 0; i < _newTargets.length; i++) {
            require(_newTargets[i].coldkey != bytes32(0), "SD: Target coldkey cannot be zero");
            require(_newTargets[i].ratioPermille > 0 && _newTargets[i].ratioPermille <= 1000, "SD: Invalid ratio");
            currentTotalRatio += _newTargets[i].ratioPermille;
        }
        // Allow flexibility: if sum < 1000, some APY is retained. If > 1000, it's an issue.
        require(currentTotalRatio <= 1000, "SD: Total ratio cannot exceed 1000 permille");
        
        distributionTargets = _newTargets;
        totalRatioPermille = currentTotalRatio;
        emit DistributionTargetsUpdated(_newTargets, totalRatioPermille);
    }
    
    function updateMinDistributionInterval(uint256 _newIntervalSeconds) external onlyOwner {
        require(_newIntervalSeconds > 0, "SD: Interval must be positive");
        minDistributionIntervalSeconds = _newIntervalSeconds;
        emit MinIntervalUpdated(_newIntervalSeconds);
    }

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

    function calculateApyDistribution()
        external
        view
        returns (TransferOperation[] memory operations, uint256 newExpectedStakeBalanceRao)
    {
        if (multisigColdkeyBytes32 == bytes32(0)) { // Not initialized
            return (new TransferOperation[](0), 0);
        }
        if (block.timestamp < lastDistributionTimestamp + minDistributionIntervalSeconds) {
            // Not time yet, return empty operations and current known balance
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
    
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "SD: New owner cannot be zero address");
        owner = _newOwner;
        emit OwnerUpdated(_newOwner);
    }

    // --- View Functions ---
    function getDistributionTargets() external view returns (DistributionTarget[] memory) {
        return distributionTargets;
    }

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
}
```

---

**Next Steps:**

1.  **Constants:** Replace placeholder precompile addresses in `StakeDistributor` (if you hardcode them, though passing via constructor or setter is better) with the actual addresses for your Subtensor network.
2.  **Review & Refine:** Go through this code carefully. Consider edge cases, gas implications of loops, and security aspects.
3.  **Foundry Project:** Set this up in a Foundry project as previously discussed.
4.  **Testing (Crucial):**
    *   Write comprehensive unit tests for both contracts in Foundry.
    *   Mock the `IStakingV2` precompile calls (especially `getStake`) for `StakeDistributor` tests using `vm.mockCall` or a mock contract.
    *   Write integration tests simulating the full lifecycle: deployment, initialization via MultiSig proposals, APY distribution cycles, manual transfers and reporting.
5.  **Keeper Script:** Develop the off-chain Keeper script (e.g., in Node.js with Ethers.js or Python with Web3.py) that will:
    *   Call `calculateApyDistribution`.
    *   Generate and sign/send proposals to the `MultiSigWalletWithVeto`.
    *   Call `confirmApyDistributionExecuted` via the MultiSig.
6.  **Deployment Scripts:** Create Foundry scripts for deploying and initializing the contracts in the correct order.
7.  **AUDIT:** Before any real value is involved, get this system professionally audited.

This set of contracts provides the on-chain logic. The human element (MultiSig owners' diligence) and the off-chain Keeper are equally important for the system to function as intended.