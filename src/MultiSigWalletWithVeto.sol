// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MultiSigWalletWithVeto
 * @dev A multi-signature wallet where one owner proposes transactions and others can veto within a time period.
 * If not enough vetos are cast, the transaction becomes executable after the veto period.
 */
contract MultiSigWalletWithVeto {
    // State variables
    address[] public owners;
    mapping(address => bool) public isOwner;
    uint256 public ownerCount;
    uint256 public vetoesRequiredToCancel;
    uint256 public vetoDuration;
    Proposal[] public proposals;
    uint256 public proposalCount;
    mapping(uint256 => mapping(address => bool)) public proposalVetoes;

    // Struct to represent a transaction proposal
    struct Proposal {
        address proposer;          // Address of the owner who proposed the transaction
        address target;            // Target address for the transaction
        uint256 value;             // ETH value to be sent with the transaction
        bytes data;                // Calldata for the transaction
        uint256 proposalTime;      // Timestamp when the proposal was submitted
        uint256 vetoDeadline;      // Timestamp when the veto period ends
        uint256 vetoCount;         // Number of vetos received
        bool executed;             // True if the proposal has been successfully executed
        bool cancelled;            // True if the proposal was cancelled due to sufficient vetos
    }

    // Events
    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed removedOwner);
    event VetoRequirementChanged(uint256 newVetoesRequired);
    event VetoDurationChanged(uint256 newVetoDuration);
    event ProposalSubmitted(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed target,
        uint256 value,
        bytes data,
        uint256 vetoDeadline
    );
    event ProposalVetoed(uint256 indexed proposalId, address indexed vetoer);
    event ProposalCancelled(uint256 indexed proposalId);
    event ProposalExecutionReady(uint256 indexed proposalId);
    event ProposalExecuted(uint256 indexed proposalId, bytes returnData);
    event ExecutionFailed(uint256 indexed proposalId, bytes returnData);
    event TransactionExecuted(
        uint256 indexed proposalId,
        address indexed target,
        uint256 value,
        bytes data
    );

    // Modifiers
    modifier onlyOwner() {
        require(isOwner[msg.sender], "MultiSig: Not an owner");
        _;
    }

    modifier proposalExists(uint256 proposalId) {
        require(proposalId < proposalCount, "MultiSig: Proposal does not exist");
        _;
    }

    /**
     * @dev Constructor to initialize the wallet with owners and parameters
     * @param _initialOwners Array of initial owner addresses
     * @param _vetoesRequired Number of vetos required to cancel a proposal
     * @param _durationSeconds Duration of the veto period in seconds
     */
    constructor(address[] memory _initialOwners, uint256 _vetoesRequired, uint256 _durationSeconds) {
        require(_initialOwners.length > 0, "MultiSig: No owners provided");
        require(_vetoesRequired > 0, "MultiSig: Veto requirement must be > 0");
        require(
            _vetoesRequired <= _initialOwners.length - 1,
            "MultiSig: Veto requirement too high"
        );
        require(_durationSeconds > 0, "MultiSig: Veto duration must be > 0");

        for (uint256 i = 0; i < _initialOwners.length; i++) {
            address owner = _initialOwners[i];
            
            require(owner != address(0), "MultiSig: Zero address cannot be owner");
            require(!isOwner[owner], "MultiSig: Duplicate owner");
            
            isOwner[owner] = true;
            owners.push(owner);
            
            emit OwnerAdded(owner);
        }
        
        ownerCount = _initialOwners.length;
        vetoesRequiredToCancel = _vetoesRequired;
        vetoDuration = _durationSeconds;
    }

    /**
     * @dev Veto a proposed transaction
     * @param proposalId ID of the proposal to veto
     */
    function vetoTransaction(uint256 proposalId) 
        external 
        onlyOwner 
        proposalExists(proposalId) 
    {
        Proposal storage proposal = proposals[proposalId];
        
        require(msg.sender != proposal.proposer, "MultiSig: Proposer cannot veto");
        require(!proposalVetoes[proposalId][msg.sender], "MultiSig: Already vetoed");
        require(!proposal.executed, "MultiSig: Already executed");
        require(!proposal.cancelled, "MultiSig: Already cancelled");
        require(
            block.timestamp < proposal.vetoDeadline,
            "MultiSig: Veto period ended"
        );
        
        proposalVetoes[proposalId][msg.sender] = true;
        proposal.vetoCount++;
        
        emit ProposalVetoed(proposalId, msg.sender);
        
        if (proposal.vetoCount >= vetoesRequiredToCancel) {
            proposal.cancelled = true;
            emit ProposalCancelled(proposalId);
        }
    }

    /**
     * @dev Execute a transaction after the veto period if not cancelled
     * @param proposalId ID of the proposal to execute
     */
    function executeTransaction(uint256 proposalId) 
        external 
        proposalExists(proposalId) 
    {
        Proposal storage proposal = proposals[proposalId];
        
        require(proposal.proposer != address(0), "MultiSig: Proposal does not exist");
        require(!proposal.executed, "MultiSig: Already executed");
        require(!proposal.cancelled, "MultiSig: Proposal was cancelled");
        require(
            block.timestamp >= proposal.vetoDeadline,
            "MultiSig: Veto period not ended"
        );
        require(
            proposal.vetoCount < vetoesRequiredToCancel,
            "MultiSig: Sufficient vetos to cancel"
        );
        
        // Mark as executed before external call (Checks-Effects-Interactions)
        proposal.executed = true;
        
        emit ProposalExecutionReady(proposalId);
        
        // Execute the transaction
        (bool success, bytes memory returnData) = proposal.target.call{value: proposal.value}(
            proposal.data
        );
        
        if (success) {
            emit ProposalExecuted(proposalId, returnData);
        } else {
            emit ExecutionFailed(proposalId, returnData);
            revert("MultiSig: Transaction execution failed");
        }
    }

    // ---------------------------------------------------------------------
    // PROPOSAL CREATION — single source of truth
    // ---------------------------------------------------------------------

    /// @dev Common implementation for creating a proposal.  
    ///      Accepts `bytes memory` so internal callers can hand-over data
    ///      they just encoded without fighting calldata ↔ memory rules.
    function _createProposal(
        address target,
        uint256 value,
        bytes memory data
    ) internal returns (uint256 proposalId) {
        require(target != address(0), "MultiSig: Target cannot be zero address");

        proposalId = proposalCount;

        proposals.push(
            Proposal({
                proposer: msg.sender,
                target:   target,
                value:    value,
                data:     data,
                proposalTime: block.timestamp,
                vetoDeadline: block.timestamp + vetoDuration,
                vetoCount: 0,
                executed:  false,
                cancelled: false
            })
        );

        proposalCount++;

        emit ProposalSubmitted(
            proposalId,
            msg.sender,
            target,
            value,
            data,
            block.timestamp + vetoDuration
        );
    }

    /**
     * @dev Public entrypoint used by owners.
     *      Thin wrapper → drops into `_createProposal`.
     */
    function proposeTransaction(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOwner returns (uint256) {
        return _createProposal(target, value, data);
    }

    // Administrative proposal helper functions
    
    /**
     * @dev Proposes adding a new owner
     * @param newOwner Address of the new owner to add
     * @return proposalId ID of the created proposal
     */
    function proposeAddOwner(address newOwner) external onlyOwner returns (uint256) {
        bytes memory data = abi.encodeWithSelector(this._addOwner.selector, newOwner);
        return _createProposal(address(this), 0, data);
    }
    
    /**
     * @dev Proposes removing an existing owner
     * @param ownerToRemove Address of the owner to remove
     * @return proposalId ID of the created proposal
     */
    function proposeRemoveOwner(address ownerToRemove) external onlyOwner returns (uint256) {
        bytes memory data = abi.encodeWithSelector(this._removeOwner.selector, ownerToRemove);
        return _createProposal(address(this), 0, data);
    }
    
    /**
     * @dev Proposes changing the veto requirement
     * @param newVetoesRequired New number of vetos required to cancel
     * @return proposalId ID of the created proposal
     */
    function proposeChangeVetoRequirement(uint256 newVetoesRequired) external onlyOwner returns (uint256) {
        bytes memory data = abi.encodeWithSelector(this._changeVetoRequirement.selector, newVetoesRequired);
        return _createProposal(address(this), 0, data);
    }
    
    /**
     * @dev Proposes changing the veto duration
     * @param newDurationSeconds New duration for the veto period in seconds
     * @return proposalId ID of the created proposal
     */
    function proposeChangeVetoDuration(uint256 newDurationSeconds) external onlyOwner returns (uint256) {
        bytes memory data = abi.encodeWithSelector(this._changeVetoDuration.selector, newDurationSeconds);
        return _createProposal(address(this), 0, data);
    }

    // Internal administrative functions
    
    /**
     * @dev Internal function to add a new owner
     * @param newOwner Address of the new owner
     */
    function _addOwner(address newOwner) external {
        require(msg.sender == address(this), "MultiSig: Only callable through proposal");
        require(newOwner != address(0), "MultiSig: Zero address cannot be owner");
        require(!isOwner[newOwner], "MultiSig: Already an owner");
        
        isOwner[newOwner] = true;
        owners.push(newOwner);
        ownerCount++;
        
        emit OwnerAdded(newOwner);
    }
    
    /**
     * @dev Internal function to remove an existing owner
     * @param ownerToRemove Address of the owner to remove
     */
    function _removeOwner(address ownerToRemove) external {
        require(msg.sender == address(this), "MultiSig: Only callable through proposal");
        require(isOwner[ownerToRemove], "MultiSig: Not an owner");
        require(ownerCount > 1, "MultiSig: Cannot remove last owner");
        
        isOwner[ownerToRemove] = false;
        
        // Remove from owners array
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == ownerToRemove) {
                // Move the last element to the position of the removed owner
                owners[i] = owners[owners.length - 1];
                // Remove the last element
                owners.pop();
                break;
            }
        }
        
        ownerCount--;
        
        // Ensure vetoesRequiredToCancel is still valid
        if (vetoesRequiredToCancel > ownerCount - 1) {
            vetoesRequiredToCancel = ownerCount - 1;
            emit VetoRequirementChanged(vetoesRequiredToCancel);
        }
        
        emit OwnerRemoved(ownerToRemove);
    }
    
    /**
     * @dev Internal function to change the veto requirement
     * @param newVetoesRequired New number of vetos required to cancel
     */
    function _changeVetoRequirement(uint256 newVetoesRequired) external {
        require(msg.sender == address(this), "MultiSig: Only callable through proposal");
        require(newVetoesRequired > 0, "MultiSig: Veto requirement must be > 0");
        require(
            newVetoesRequired <= ownerCount - 1,
            "MultiSig: Veto requirement too high"
        );
        
        vetoesRequiredToCancel = newVetoesRequired;
        
        emit VetoRequirementChanged(newVetoesRequired);
    }
    
    /**
     * @dev Internal function to change the veto duration
     * @param newDurationSeconds New duration for the veto period in seconds
     */
    function _changeVetoDuration(uint256 newDurationSeconds) external {
        require(msg.sender == address(this), "MultiSig: Only callable through proposal");
        require(newDurationSeconds > 0, "MultiSig: Veto duration must be > 0");
        
        vetoDuration = newDurationSeconds;
        
        emit VetoDurationChanged(newDurationSeconds);
    }

    // View functions
    
    /**
     * @dev Get details of a specific proposal
     * @param proposalId ID of the proposal
     * @return Proposal struct with all details
     */
    function getProposal(uint256 proposalId) 
        external 
        view 
        proposalExists(proposalId) 
        returns (Proposal memory) 
    {
        return proposals[proposalId];
    }
    
    /**
     * @dev Get the list of all current owners
     * @return Array of owner addresses
     */
    function getOwners() external view returns (address[] memory) {
        return owners;
    }
    
    /**
     * @dev Get the list of addresses that vetoed a specific proposal
     * @param proposalId ID of the proposal
     * @return Array of vetoer addresses
     */
    function getVetoers(uint256 proposalId) 
        external 
        view 
        proposalExists(proposalId) 
        returns (address[] memory) 
    {
        uint256 vetoCount = 0;
        
        // First, count the number of vetoers
        for (uint256 i = 0; i < owners.length; i++) {
            if (proposalVetoes[proposalId][owners[i]]) {
                vetoCount++;
            }
        }
        
        // Create and populate the result array
        address[] memory vetoers = new address[](vetoCount);
        uint256 index = 0;
        
        for (uint256 i = 0; i < owners.length; i++) {
            if (proposalVetoes[proposalId][owners[i]]) {
                vetoers[index] = owners[i];
                index++;
            }
        }
        
        return vetoers;
    }
    
    /**
     * @dev Check if a proposal is ready to be executed
     * @param proposalId ID of the proposal
     * @return True if the proposal can be executed
     */
    function isProposalExecutable(uint256 proposalId) 
        external 
        view 
        proposalExists(proposalId) 
        returns (bool) 
    {
        Proposal storage proposal = proposals[proposalId];
        
        return (
            !proposal.executed &&
            !proposal.cancelled &&
            block.timestamp >= proposal.vetoDeadline &&
            proposal.vetoCount < vetoesRequiredToCancel
        );
    }
    
    /**
     * @dev Receive function to allow the contract to receive ETH
     */
    receive() external payable {}
} 