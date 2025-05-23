// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MultiSigWalletWithVeto} from "../src/MultiSigWalletWithVeto.sol";

contract TestTarget {
    uint256 public value;
    bool public shouldRevert;

    function setValue(uint256 _value) external {
        require(!shouldRevert, "TestTarget: Reverting as configured");
        value = _value;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    receive() external payable {}
}

contract RevertingContract {
    function alwaysReverts() external pure {
        revert("RevertingContract: Always reverts");
    }
}

contract MultiSigWalletWithVetoTest is Test {
    MultiSigWalletWithVeto public wallet;
    TestTarget public target;

    address[] public owners;
    address public owner1;
    address public owner2;
    address public owner3;
    address public owner4;
    address public nonOwner;

    uint256 public constant VETO_DURATION = 3 days;
    uint256 public constant VETO_REQUIREMENT = 2;

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
    event OwnerAdded(address indexed newOwner);
    event OwnerRemoved(address indexed removedOwner);
    event VetoRequirementChanged(uint256 newVetoesRequired);
    event VetoDurationChanged(uint256 newVetoDuration);

    function setUp() public {
        // Setup accounts
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        owner3 = makeAddr("owner3");
        owner4 = makeAddr("owner4");
        nonOwner = makeAddr("nonOwner");

        // Fund accounts
        vm.deal(owner1, 10 ether);
        vm.deal(owner2, 10 ether);
        vm.deal(owner3, 10 ether);
        vm.deal(owner4, 10 ether);

        // Setup owners array
        owners.push(owner1);
        owners.push(owner2);
        owners.push(owner3);
        owners.push(owner4);

        // Deploy wallet
        wallet = new MultiSigWalletWithVeto(owners, VETO_REQUIREMENT, VETO_DURATION);

        // Deploy test target contract
        target = new TestTarget();
    }

    function test_Constructor() public {
        // Check initial state
        assertEq(wallet.ownerCount(), 4);
        assertEq(wallet.vetoesRequiredToCancel(), VETO_REQUIREMENT);
        assertEq(wallet.vetoDuration(), VETO_DURATION);

        // Check owners
        assertTrue(wallet.isOwner(owner1));
        assertTrue(wallet.isOwner(owner2));
        assertTrue(wallet.isOwner(owner3));
        assertTrue(wallet.isOwner(owner4));
        assertFalse(wallet.isOwner(nonOwner));

        // Check getOwners
        address[] memory walletOwners = wallet.getOwners();
        assertEq(walletOwners.length, 4);
        assertEq(walletOwners[0], owner1);
        assertEq(walletOwners[1], owner2);
        assertEq(walletOwners[2], owner3);
        assertEq(walletOwners[3], owner4);
    }

    function test_ProposeTransaction() public {
        // Prepare transaction data
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);

        // Propose transaction as owner1
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // Check proposal was created
        assertEq(proposalId, 0);
        assertEq(wallet.proposalCount(), 1);

        // Check proposal details
        MultiSigWalletWithVeto.Proposal memory proposal = wallet.getProposal(proposalId);
        assertEq(proposal.proposer, owner1);
        assertEq(proposal.target, address(target));
        assertEq(proposal.value, 0);
        assertEq(proposal.data, data);
        assertEq(proposal.vetoCount, 0);
        assertFalse(proposal.executed);
        assertFalse(proposal.cancelled);
        assertEq(proposal.vetoDeadline, block.timestamp + VETO_DURATION);
    }

    function test_ProposeTransactionEmitsEvent() public {
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);

        vm.prank(owner1);
        vm.expectEmit(true, true, true, true);
        emit ProposalSubmitted(
            0, // proposalId
            owner1, // proposer
            address(target), // target
            0, // value
            data, // data
            block.timestamp + VETO_DURATION // vetoDeadline
        );
        wallet.proposeTransaction(address(target), 0, data);
    }

    function test_RevertWhen_NonOwnerProposesTransaction() public {
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);

        vm.prank(nonOwner);
        vm.expectRevert("MultiSig: Not an owner");
        wallet.proposeTransaction(address(target), 0, data);
    }

    function test_VetoTransaction() public {
        // Propose a transaction
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // Veto as owner2
        vm.prank(owner2);
        wallet.vetoTransaction(proposalId);

        // Check veto was recorded
        MultiSigWalletWithVeto.Proposal memory proposal = wallet.getProposal(proposalId);
        assertEq(proposal.vetoCount, 1);
        assertTrue(wallet.proposalVetoes(proposalId, owner2));

        // Check proposal not cancelled yet (need 2 vetos)
        assertFalse(proposal.cancelled);
    }

    function test_VetoTransactionEmitsEvent() public {
        // Propose a transaction
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // Expect veto event
        vm.prank(owner2);
        vm.expectEmit(true, true, false, false);
        emit ProposalVetoed(proposalId, owner2);
        wallet.vetoTransaction(proposalId);
    }

    function test_CancelProposalWithSufficientVetos() public {
        // Propose a transaction
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // First veto
        vm.prank(owner2);
        wallet.vetoTransaction(proposalId);

        // Second veto (should cancel the proposal)
        vm.prank(owner3);
        vm.expectEmit(true, false, false, false);
        emit ProposalCancelled(proposalId);
        wallet.vetoTransaction(proposalId);

        // Check proposal is cancelled
        MultiSigWalletWithVeto.Proposal memory proposal = wallet.getProposal(proposalId);
        assertTrue(proposal.cancelled);
        assertEq(proposal.vetoCount, 2);
    }

    function test_RevertWhen_ProposerVetosOwnProposal() public {
        // Propose a transaction
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // Try to veto own proposal
        vm.prank(owner1);
        vm.expectRevert("MultiSig: Proposer cannot veto");
        wallet.vetoTransaction(proposalId);
    }

    function test_RevertWhen_DoubleVeto() public {
        // Propose a transaction
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // First veto
        vm.prank(owner2);
        wallet.vetoTransaction(proposalId);

        // Try to veto again
        vm.prank(owner2);
        vm.expectRevert("MultiSig: Already vetoed");
        wallet.vetoTransaction(proposalId);
    }

    function test_RevertWhen_VetoAfterDeadline() public {
        // Propose a transaction
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Try to veto after deadline
        vm.prank(owner2);
        vm.expectRevert("MultiSig: Veto period ended");
        wallet.vetoTransaction(proposalId);
    }

    function test_ExecuteTransaction() public {
        // Create a proposal
        vm.prank(owner1);
        uint256 proposalId =
            wallet.proposeTransaction(address(target), 0, abi.encodeWithSelector(target.setValue.selector, 42));

        // Fast forward past veto deadline
        vm.warp(block.timestamp + wallet.vetoDuration() + 1);

        // Execute the proposal
        wallet.executeTransaction(proposalId);

        // Check that the value was set
        assertEq(target.value(), 42);
    }

    function test_RevertWhen_ExecuteBeforeDeadline() public {
        // Create a proposal
        vm.prank(owner1);
        uint256 proposalId =
            wallet.proposeTransaction(address(target), 0, abi.encodeWithSelector(target.setValue.selector, 42));

        // Try to execute before deadline
        vm.expectRevert("MultiSig: Veto period not ended");
        wallet.executeTransaction(proposalId);
    }

    function test_RevertWhen_ExecuteCancelledProposal() public {
        // Propose a transaction
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // Cancel with sufficient vetos
        vm.prank(owner2);
        wallet.vetoTransaction(proposalId);
        vm.prank(owner3);
        wallet.vetoTransaction(proposalId);

        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Try to execute cancelled proposal
        vm.expectRevert("MultiSig: Proposal was cancelled");
        wallet.executeTransaction(proposalId);
    }

    function test_ExecutionFailedEvent() public {
        // Deploy a contract that will revert
        RevertingContract revertingContract = new RevertingContract();

        // Create a proposal that will revert
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(
            address(revertingContract), 0, abi.encodeWithSelector(revertingContract.alwaysReverts.selector)
        );

        // Fast forward past veto deadline
        vm.warp(block.timestamp + wallet.vetoDuration() + 1);

        // Execute the proposal (should revert with MultiSig: Transaction execution failed)
        vm.expectRevert("MultiSig: Transaction execution failed");
        wallet.executeTransaction(proposalId);
    }

    function test_ProposeAndExecuteEthTransfer() public {
        // Fund the wallet
        vm.deal(address(wallet), 1 ether);

        // Initial balance of target
        uint256 initialBalance = address(target).balance;

        // Propose a transaction to send 0.5 ETH
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0.5 ether, "");

        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Execute the transaction
        wallet.executeTransaction(proposalId);

        // Check ETH was transferred
        assertEq(address(target).balance, initialBalance + 0.5 ether);
    }

    function test_AdminFunctions() public {
        // Test adding a new owner
        address newOwner = makeAddr("newOwner");

        // Propose adding new owner
        vm.prank(owner1);
        uint256 addOwnerProposalId = wallet.proposeAddOwner(newOwner);

        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Execute the proposal
        wallet.executeTransaction(addOwnerProposalId);

        // Check new owner was added
        assertTrue(wallet.isOwner(newOwner));
        assertEq(wallet.ownerCount(), 5);

        // Test removing an owner
        vm.prank(owner2);
        uint256 removeOwnerProposalId = wallet.proposeRemoveOwner(owner3);

        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Execute the proposal
        wallet.executeTransaction(removeOwnerProposalId);

        // Check owner was removed
        assertFalse(wallet.isOwner(owner3));
        assertEq(wallet.ownerCount(), 4);

        // Test changing veto requirement
        uint256 newVetoRequirement = 3;
        vm.prank(owner1);
        uint256 changeVetoReqProposalId = wallet.proposeChangeVetoRequirement(newVetoRequirement);

        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Execute the proposal
        wallet.executeTransaction(changeVetoReqProposalId);

        // Check veto requirement was updated
        assertEq(wallet.vetoesRequiredToCancel(), newVetoRequirement);

        // Test changing veto duration
        uint256 newVetoDuration = 7 days;
        vm.prank(owner2);
        uint256 changeVetoDurationProposalId = wallet.proposeChangeVetoDuration(newVetoDuration);

        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Execute the proposal
        wallet.executeTransaction(changeVetoDurationProposalId);

        // Check veto duration was updated
        assertEq(wallet.vetoDuration(), newVetoDuration);
    }

    function test_GetVetoers() public {
        // Propose a transaction
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // No vetoers initially
        address[] memory initialVetoers = wallet.getVetoers(proposalId);
        assertEq(initialVetoers.length, 0);

        // Add some vetos
        vm.prank(owner2);
        wallet.vetoTransaction(proposalId);
        vm.prank(owner3);
        wallet.vetoTransaction(proposalId);

        // Check vetoers
        address[] memory vetoers = wallet.getVetoers(proposalId);
        assertEq(vetoers.length, 2);

        // Check the vetoers are correct (order may vary)
        bool foundOwner2 = false;
        bool foundOwner3 = false;

        for (uint256 i = 0; i < vetoers.length; i++) {
            if (vetoers[i] == owner2) foundOwner2 = true;
            if (vetoers[i] == owner3) foundOwner3 = true;
        }

        assertTrue(foundOwner2);
        assertTrue(foundOwner3);
    }

    function test_IsProposalExecutable() public {
        // Propose a transaction
        bytes memory data = abi.encodeWithSelector(TestTarget.setValue.selector, 42);
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(target), 0, data);

        // Not executable before deadline
        assertFalse(wallet.isProposalExecutable(proposalId));

        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Should be executable now
        assertTrue(wallet.isProposalExecutable(proposalId));

        // Add enough vetos to cancel
        vm.warp(block.timestamp - VETO_DURATION - 1); // Go back before deadline
        vm.prank(owner2);
        wallet.vetoTransaction(proposalId);
        vm.prank(owner3);
        wallet.vetoTransaction(proposalId);

        // Fast forward past veto deadline again
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Should not be executable due to cancellation
        assertFalse(wallet.isProposalExecutable(proposalId));

        // Propose another transaction
        vm.prank(owner1);
        uint256 proposalId2 = wallet.proposeTransaction(address(target), 0, data);

        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);

        // Execute it
        wallet.executeTransaction(proposalId2);

        // Should not be executable after execution
        assertFalse(wallet.isProposalExecutable(proposalId2));
    }

    function test_RevertWhen_InvalidConstructorParams() public {
        // Empty owners array
        address[] memory emptyOwners = new address[](0);
        vm.expectRevert("MultiSig: No owners provided");
        new MultiSigWalletWithVeto(emptyOwners, 1, 1 days);

        // Zero veto requirement
        vm.expectRevert("MultiSig: Veto requirement must be > 0");
        new MultiSigWalletWithVeto(owners, 0, 1 days);

        // Veto requirement too high
        vm.expectRevert("MultiSig: Veto requirement too high");
        new MultiSigWalletWithVeto(owners, 5, 1 days);

        // Zero veto duration
        vm.expectRevert("MultiSig: Veto duration must be > 0");
        new MultiSigWalletWithVeto(owners, 1, 0);

        // Duplicate owner
        address[] memory duplicateOwners = new address[](3);
        duplicateOwners[0] = owner1;
        duplicateOwners[1] = owner2;
        duplicateOwners[2] = owner1; // Duplicate
        vm.expectRevert("MultiSig: Duplicate owner");
        new MultiSigWalletWithVeto(duplicateOwners, 1, 1 days);

        // Zero address owner
        address[] memory zeroOwners = new address[](3);
        zeroOwners[0] = owner1;
        zeroOwners[1] = address(0); // Zero address
        zeroOwners[2] = owner2;
        vm.expectRevert("MultiSig: Zero address cannot be owner");
        new MultiSigWalletWithVeto(zeroOwners, 1, 1 days);
    }

    function test_AutoAdjustVetoRequirementOnOwnerRemoval() public {
        // Start with 4 owners and veto requirement of 3
        vm.prank(owner1);
        uint256 changeVetoReqProposalId = wallet.proposeChangeVetoRequirement(3);
        vm.warp(block.timestamp + VETO_DURATION + 1);
        wallet.executeTransaction(changeVetoReqProposalId);
        assertEq(wallet.vetoesRequiredToCancel(), 3);

        // Remove an owner, which should auto-adjust veto requirement to 2
        // (since we now have 3 owners, and max veto requirement is ownerCount - 1)
        vm.prank(owner2);
        uint256 removeOwnerProposalId = wallet.proposeRemoveOwner(owner3);
        vm.warp(block.timestamp + VETO_DURATION + 1);
        wallet.executeTransaction(removeOwnerProposalId);

        // Check veto requirement was auto-adjusted to 2 (not 3)
        assertEq(wallet.vetoesRequiredToCancel(), 2);

        // Remove another owner, which should auto-adjust veto requirement to 1
        // (since we now have 2 owners, and max veto requirement is ownerCount - 1)
        vm.prank(owner1);
        uint256 removeOwner2ProposalId = wallet.proposeRemoveOwner(owner4);
        vm.warp(block.timestamp + VETO_DURATION + 1);
        wallet.executeTransaction(removeOwner2ProposalId);

        // Check veto requirement was auto-adjusted to 1
        assertEq(wallet.vetoesRequiredToCancel(), 1);
    }
}
