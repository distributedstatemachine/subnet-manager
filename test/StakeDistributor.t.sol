// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StakeDistributor} from "../src/StakeDistributor.sol";
import {MultiSigWalletWithVeto} from "../src/MultiSigWalletWithVeto.sol";
import {IStakingV2} from "../src/interfaces/IStakingV2.sol";

// Mock contract for IStakingV2 precompile
contract MockStakingV2 {
    mapping(bytes32 => mapping(address => mapping(uint16 => uint256))) private stakes;
    
    function setStake(bytes32 hotkey, bytes32 coldkey, uint16 netuid, uint256 amount) external {
        address coldkeyAddr = bytes32ToAddress(coldkey);
        stakes[hotkey][coldkeyAddr][netuid] = amount;
    }
    
    function getStake(bytes32 hotkey, bytes32 coldkey, uint16 netuid) external view returns (uint256) {
        address coldkeyAddr = bytes32ToAddress(coldkey);
        return stakes[hotkey][coldkeyAddr][netuid];
    }
    
    function transferStake(
        bytes32 destinationColdkey,
        bytes32 hotkey,
        uint16 originNetuid,
        uint16 destinationNetuid,
        uint256 amountAlpha
    ) external {
        // Mock implementation - just reduce the stake
        if (stakes[hotkey][msg.sender][originNetuid] >= amountAlpha) {
            stakes[hotkey][msg.sender][originNetuid] -= amountAlpha;
        }
    }
    
    function bytes32ToAddress(bytes32 _bytes32) internal pure returns (address) {
        return address(uint160(uint256(_bytes32)));
    }
}

contract StakeDistributorTest is Test {
    StakeDistributor public distributor;
    MultiSigWalletWithVeto public wallet;
    MockStakingV2 public mockStaking;
    
    address[] public owners;
    address public owner1;
    address public owner2;
    address public owner3;
    address public nonOwner;
    
    bytes32 public constant COLDKEY = bytes32(uint256(1));
    bytes32 public constant HOTKEY = bytes32(uint256(2));
    bytes32 public constant TARGET1 = bytes32(uint256(3));
    bytes32 public constant TARGET2 = bytes32(uint256(4));
    uint16 public constant NETUID = 1;
    uint256 public constant INITIAL_STAKE = 10000 ether;
    uint256 public constant VETO_DURATION = 3 days;
    uint256 public constant VETO_REQUIREMENT = 2;
    uint256 public constant MIN_INTERVAL = 1 days;
    
    function setUp() public {
        // Setup accounts
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        owner3 = makeAddr("owner3");
        nonOwner = makeAddr("nonOwner");
        
        // Setup owners array
        owners.push(owner1);
        owners.push(owner2);
        owners.push(owner3);
        
        // Deploy mock staking contract
        mockStaking = new MockStakingV2();
        
        // Deploy wallet
        wallet = new MultiSigWalletWithVeto(owners, VETO_REQUIREMENT, VETO_DURATION);
        
        // Deploy distributor with the new interval parameter
        distributor = new StakeDistributor(address(mockStaking), address(wallet), MIN_INTERVAL);
        
        // Set initial stake in mock
        mockStaking.setStake(HOTKEY, COLDKEY, NETUID, INITIAL_STAKE);
    }
    
    function test_Constructor() public {
        assertEq(distributor.iStakingV2Precompile(), address(mockStaking));
        assertEq(distributor.owner(), address(wallet));
    }
    
    function test_Initialize() public {
        // Create distribution targets
        StakeDistributor.DistributionTarget[] memory targets = new StakeDistributor.DistributionTarget[](2);
        targets[0] = StakeDistributor.DistributionTarget(TARGET1, 500); // 50%
        targets[1] = StakeDistributor.DistributionTarget(TARGET2, 500); // 50%
        
        // Initialize via wallet
        bytes memory initData = abi.encodeWithSelector(
            distributor.initialize.selector,
            COLDKEY,
            HOTKEY,
            NETUID,
            targets,
            INITIAL_STAKE,
            MIN_INTERVAL
        );
        
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(distributor), 0, initData);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute the proposal
        wallet.executeTransaction(proposalId);
        
        // Check initialization
        assertEq(distributor.multisigColdkeyBytes32(), COLDKEY);
        assertEq(distributor.associatedHotkeyBytes32(), HOTKEY);
        assertEq(distributor.netuid(), NETUID);
        assertEq(distributor.lastKnownStakeBalanceRao(), INITIAL_STAKE);
        assertEq(distributor.minDistributionIntervalSeconds(), MIN_INTERVAL);
        assertEq(distributor.totalRatioPermille(), 1000);
        
        // Check targets
        StakeDistributor.DistributionTarget[] memory storedTargets = distributor.getDistributionTargets();
        assertEq(storedTargets.length, 2);
        assertEq(storedTargets[0].coldkey, TARGET1);
        assertEq(storedTargets[0].ratioPermille, 500);
        assertEq(storedTargets[1].coldkey, TARGET2);
        assertEq(storedTargets[1].ratioPermille, 500);
    }
    
    function test_RevertWhen_NonOwnerInitializes() public {
        StakeDistributor.DistributionTarget[] memory targets = new StakeDistributor.DistributionTarget[](1);
        targets[0] = StakeDistributor.DistributionTarget(TARGET1, 1000);
        
        vm.prank(nonOwner);
        vm.expectRevert("StakeDistributor: Caller is not the owner");
        distributor.initialize(COLDKEY, HOTKEY, NETUID, targets, INITIAL_STAKE, MIN_INTERVAL);
    }
    
    function test_CalculateApyDistribution() public {
        // Initialize distributor
        _initializeDistributor();
        
        // Increase stake to simulate APY
        uint256 apyAmount = 1000 ether;
        mockStaking.setStake(HOTKEY, COLDKEY, NETUID, INITIAL_STAKE + apyAmount);
        
        // Fast forward past min interval
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        
        // Calculate distribution
        (StakeDistributor.TransferOperation[] memory ops, uint256 newBalance) = distributor.calculateApyDistribution();
        
        // Check results
        assertEq(ops.length, 2);
        assertEq(ops[0].destinationColdkey, TARGET1);
        assertEq(ops[0].amountRao, 500 ether); // 50% of APY
        assertEq(ops[1].destinationColdkey, TARGET2);
        assertEq(ops[1].amountRao, 500 ether); // 50% of APY
        assertEq(newBalance, INITIAL_STAKE); // Original stake after distribution
    }
    
    function test_NoDistributionBeforeInterval() public {
        // Initialize distributor
        _initializeDistributor();
        
        // Check lastDistributionTimestamp
        (, , , , , uint256 lastDistTime, , ) = distributor.getConfig();
        console.log("lastDistributionTimestamp:", lastDistTime);
        
        // Increase stake to simulate APY
        uint256 apyAmount = 1000 ether;
        mockStaking.setStake(HOTKEY, COLDKEY, NETUID, INITIAL_STAKE + apyAmount);
        
        // Try to calculate distribution before min interval has passed
        (StakeDistributor.TransferOperation[] memory ops, ) = distributor.calculateApyDistribution();
        
        // Should return empty array since min interval hasn't passed
        assertEq(ops.length, 0);
    }
    
    function test_NoDistributionWhenNoApy() public {
        // Initialize distributor
        _initializeDistributor();
        
        // Fast forward past min interval
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        
        // Calculate distribution (no APY earned)
        (StakeDistributor.TransferOperation[] memory ops, uint256 newBalance) = distributor.calculateApyDistribution();
        
        // Check no distribution
        assertEq(ops.length, 0);
        assertEq(newBalance, INITIAL_STAKE);
    }
    
    function test_ReportManualStakeChange() public {
        // Initialize distributor
        _initializeDistributor();
        
        // Report manual stake increase
        int256 increase = 500 ether;
        bytes memory reportData = abi.encodeWithSelector(
            distributor.reportManualStakeChange.selector,
            increase
        );
        
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(distributor), 0, reportData);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute the proposal
        wallet.executeTransaction(proposalId);
        
        // Check updated balance
        assertEq(distributor.lastKnownStakeBalanceRao(), INITIAL_STAKE + uint256(increase));
        
        // Report manual stake decrease
        int256 decrease = -300 ether;
        bytes memory reportData2 = abi.encodeWithSelector(
            distributor.reportManualStakeChange.selector,
            decrease
        );
        
        vm.prank(owner2);
        uint256 proposalId2 = wallet.proposeTransaction(address(distributor), 0, reportData2);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute the proposal
        wallet.executeTransaction(proposalId2);
        
        // Check updated balance
        assertEq(distributor.lastKnownStakeBalanceRao(), INITIAL_STAKE + uint256(increase) - uint256(-decrease));
    }
    
    function test_ConfirmApyDistributionExecuted() public {
        // Initialize distributor
        _initializeDistributor();
        
        // Increase stake to simulate APY
        uint256 apyAmount = 1000 ether;
        mockStaking.setStake(HOTKEY, COLDKEY, NETUID, INITIAL_STAKE + apyAmount);
        
        // Fast forward past min interval
        vm.warp(block.timestamp + MIN_INTERVAL + 1);
        
        // Calculate distribution
        (StakeDistributor.TransferOperation[] memory ops, ) = distributor.calculateApyDistribution();
        
        // Simulate distribution execution (in real system, this would be done via MultiSig proposals)
        uint256 totalDistributed = ops[0].amountRao + ops[1].amountRao;
        uint256 newStakeBalance = INITIAL_STAKE + apyAmount - totalDistributed;
        mockStaking.setStake(HOTKEY, COLDKEY, NETUID, newStakeBalance);
        
        // Confirm distribution
        bytes memory confirmData = abi.encodeWithSelector(
            distributor.confirmApyDistributionExecuted.selector,
            totalDistributed,
            newStakeBalance
        );
        
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(distributor), 0, confirmData);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute the proposal
        wallet.executeTransaction(proposalId);
        
        // Check updated state
        assertEq(distributor.lastKnownStakeBalanceRao(), newStakeBalance);
        assertEq(distributor.lastDistributionTimestamp(), block.timestamp);
    }
    
    function test_UpdateDistributionTargets() public {
        // Initialize distributor
        _initializeDistributor();
        
        // Create new distribution targets
        StakeDistributor.DistributionTarget[] memory newTargets = new StakeDistributor.DistributionTarget[](3);
        newTargets[0] = StakeDistributor.DistributionTarget(TARGET1, 300); // 30%
        newTargets[1] = StakeDistributor.DistributionTarget(TARGET2, 300); // 30%
        newTargets[2] = StakeDistributor.DistributionTarget(bytes32(uint256(5)), 200); // 20%
        
        // Update targets via wallet
        bytes memory updateData = abi.encodeWithSelector(
            distributor.updateDistributionTargets.selector,
            newTargets
        );
        
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(distributor), 0, updateData);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute the proposal
        wallet.executeTransaction(proposalId);
        
        // Check updated targets
        StakeDistributor.DistributionTarget[] memory storedTargets = distributor.getDistributionTargets();
        assertEq(storedTargets.length, 3);
        assertEq(storedTargets[0].coldkey, TARGET1);
        assertEq(storedTargets[0].ratioPermille, 300);
        assertEq(storedTargets[1].coldkey, TARGET2);
        assertEq(storedTargets[1].ratioPermille, 300);
        assertEq(storedTargets[2].coldkey, bytes32(uint256(5)));
        assertEq(storedTargets[2].ratioPermille, 200);
        assertEq(distributor.totalRatioPermille(), 800); // 80% total
    }
    
    function test_UpdateMinDistributionInterval() public {
        // Initialize distributor
        _initializeDistributor();
        
        // Update interval
        uint256 newInterval = 7 days;
        bytes memory updateData = abi.encodeWithSelector(
            distributor.updateMinDistributionInterval.selector,
            newInterval
        );
        
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(distributor), 0, updateData);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute the proposal
        wallet.executeTransaction(proposalId);
        
        // Check updated interval
        assertEq(distributor.minDistributionIntervalSeconds(), newInterval);
    }
    
    function test_TransferOwnership() public {
        // Initialize distributor
        _initializeDistributor();
        
        // Transfer ownership
        address newOwner = makeAddr("newOwner");
        bytes memory transferData = abi.encodeWithSelector(
            distributor.transferOwnership.selector,
            newOwner
        );
        
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(distributor), 0, transferData);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute the proposal
        wallet.executeTransaction(proposalId);
        
        // Check new owner
        assertEq(distributor.owner(), newOwner);
    }
    
    function test_RevertWhen_InvalidDistributionTargets() public {
        // Initialize distributor
        _initializeDistributor();
        
        // Create invalid targets (empty array)
        StakeDistributor.DistributionTarget[] memory invalidTargets1 = new StakeDistributor.DistributionTarget[](0);
        
        bytes memory updateData1 = abi.encodeWithSelector(
            distributor.updateDistributionTargets.selector,
            invalidTargets1
        );
        
        vm.prank(owner1);
        uint256 proposalId1 = wallet.proposeTransaction(address(distributor), 0, updateData1);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute should revert with the MultiSig error message
        vm.expectRevert("MultiSig: Transaction execution failed");
        wallet.executeTransaction(proposalId1);
        
        // Create invalid targets (zero ratio)
        StakeDistributor.DistributionTarget[] memory invalidTargets2 = new StakeDistributor.DistributionTarget[](1);
        invalidTargets2[0] = StakeDistributor.DistributionTarget(TARGET1, 0);
        
        bytes memory updateData2 = abi.encodeWithSelector(
            distributor.updateDistributionTargets.selector,
            invalidTargets2
        );
        
        vm.prank(owner1);
        uint256 proposalId2 = wallet.proposeTransaction(address(distributor), 0, updateData2);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute should revert with the MultiSig error message
        vm.expectRevert("MultiSig: Transaction execution failed");
        wallet.executeTransaction(proposalId2);
        
        // Create invalid targets (total ratio > 1000)
        StakeDistributor.DistributionTarget[] memory invalidTargets3 = new StakeDistributor.DistributionTarget[](2);
        invalidTargets3[0] = StakeDistributor.DistributionTarget(TARGET1, 600);
        invalidTargets3[1] = StakeDistributor.DistributionTarget(TARGET2, 500);
        
        bytes memory updateData3 = abi.encodeWithSelector(
            distributor.updateDistributionTargets.selector,
            invalidTargets3
        );
        
        vm.prank(owner1);
        uint256 proposalId3 = wallet.proposeTransaction(address(distributor), 0, updateData3);
        
        // Fast forward past veto deadline
        vm.warp(block.timestamp + VETO_DURATION + 1);
        
        // Execute should revert with the MultiSig error message
        vm.expectRevert("MultiSig: Transaction execution failed");
        wallet.executeTransaction(proposalId3);
    }
    
    // Helper function to initialize the distributor
    function _initializeDistributor() internal {
        StakeDistributor.DistributionTarget[] memory targets = new StakeDistributor.DistributionTarget[](2);
        targets[0] = StakeDistributor.DistributionTarget(TARGET1, 500); // 50%
        targets[1] = StakeDistributor.DistributionTarget(TARGET2, 500); // 50%
        
        bytes memory initData = abi.encodeWithSelector(
            distributor.initialize.selector,
            COLDKEY,
            HOTKEY,
            NETUID,
            targets,
            INITIAL_STAKE,
            MIN_INTERVAL
        );
        
        vm.prank(owner1);
        uint256 proposalId = wallet.proposeTransaction(address(distributor), 0, initData);
        
        vm.warp(block.timestamp + VETO_DURATION + 1);
        wallet.executeTransaction(proposalId);
    }
} 