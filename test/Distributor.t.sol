// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "../src/Distributor.sol";
import "./mocks/MockStakingV2.sol";

contract DistributorTest is Test {
    Distributor public distributor;
    MockStakingV2 public mockStaking;

    address public owner;
    address public nonOwner;
    bytes32 public constant VALIDATOR_HOTKEY = bytes32(uint256(1));
    bytes32 public constant NEW_VALIDATOR_HOTKEY = bytes32(uint256(999));
    bytes32 public constant RECIPIENT1_COLDKEY = bytes32(uint256(2));
    bytes32 public constant RECIPIENT2_COLDKEY = bytes32(uint256(3));
    bytes32 public constant CONTRACT_SS58_KEY = bytes32(uint256(4));
    uint16 public constant NETUID = 1;
    uint256 public constant INITIAL_BALANCE = 1000e9; // 1000 TAO
    uint256 public constant MIN_BLOCK_INTERVAL = 7200; // 1 day in blocks
    uint256 public constant EXISTENTIAL_AMOUNT = 1e9; // 1 TAO

    event StakeTransferred(uint256 totalAmount, uint256 newBalance);
    event RecipientTransfer(bytes32 indexed coldkey, uint256 amount, uint256 proportion);
    event TransferSkipped(string reason, uint256 calculatedAmount);
    event PrincipalDetected(uint256 amount, uint256 totalPrincipal);
    event RecipientsUpdated(uint256 recipientCount);
    event ValidatorHotkeyChanged(bytes32 oldHotkey, bytes32 newHotkey);

    function setUp() public {
        owner = makeAddr("owner");
        nonOwner = makeAddr("nonOwner");

        // Deploy mock staking contract
        mockStaking = new MockStakingV2();

        // Set up recipients: 60% to recipient1, 40% to recipient2
        bytes32[] memory recipients = new bytes32[](2);
        recipients[0] = RECIPIENT1_COLDKEY;
        recipients[1] = RECIPIENT2_COLDKEY;

        uint256[] memory proportions = new uint256[](2);
        proportions[0] = 6000; // 60%
        proportions[1] = 4000; // 40%

        // Deploy distributor
        distributor = new Distributor(owner, VALIDATOR_HOTKEY, NETUID, recipients, proportions);

        // Set the SS58 public key and mock initial balance
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(INITIAL_BALANCE)
        );

        vm.prank(owner);
        distributor.setThisSs58PublicKey(CONTRACT_SS58_KEY);
    }

    function test_Constructor() public view {
        assertEq(distributor.owner(), owner);
        assertEq(distributor.validatorHotkey(), VALIDATOR_HOTKEY);
        assertEq(distributor.netuid(), NETUID);
        assertEq(distributor.getRecipientCount(), 2);
        assertEq(distributor.totalProportion(), 10000);
        assertEq(distributor.lastTransferBlock(), block.number);
    }

    function test_RevertWhen_InvalidConstructorParams() public {
        bytes32[] memory recipients = new bytes32[](1);
        recipients[0] = RECIPIENT1_COLDKEY;
        uint256[] memory proportions = new uint256[](1);
        proportions[0] = 5000; // Only 50%, should fail

        // Invalid proportions sum
        vm.expectRevert("Proportions must sum to 10000");
        new Distributor(owner, VALIDATOR_HOTKEY, NETUID, recipients, proportions);

        // Array length mismatch
        uint256[] memory wrongProportions = new uint256[](2);
        wrongProportions[0] = 6000;
        wrongProportions[1] = 4000;

        vm.expectRevert("Array length mismatch");
        new Distributor(owner, VALIDATOR_HOTKEY, NETUID, recipients, wrongProportions);
    }

    function test_ChangeValidatorHotkey() public {
        // Mock the current stake balance
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(INITIAL_BALANCE)
        );

        // Mock the moveStake call
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("moveStake(bytes32,bytes32,uint16,uint16,uint256)")),
                VALIDATOR_HOTKEY, // originHotkey
                NEW_VALIDATOR_HOTKEY, // destinationHotkey
                NETUID, // originNetuid
                NETUID, // destinationNetuid
                INITIAL_BALANCE // amountAlpha
            ),
            abi.encode()
        );

        vm.expectEmit(true, true, false, true);
        emit ValidatorHotkeyChanged(VALIDATOR_HOTKEY, NEW_VALIDATOR_HOTKEY);

        vm.prank(owner);
        distributor.changeValidatorHotkey(NEW_VALIDATOR_HOTKEY);

        assertEq(distributor.validatorHotkey(), NEW_VALIDATOR_HOTKEY);
    }

    function test_ChangeValidatorHotkey_NoStake() public {
        // Create new distributor without setting public key (no stake)
        bytes32[] memory recipients = new bytes32[](1);
        recipients[0] = RECIPIENT1_COLDKEY;
        uint256[] memory proportions = new uint256[](1);
        proportions[0] = 10000;

        Distributor newDistributor = new Distributor(owner, VALIDATOR_HOTKEY, NETUID, recipients, proportions);

        // Set public key but mock zero balance
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(0)
        );

        vm.prank(owner);
        newDistributor.setThisSs58PublicKey(CONTRACT_SS58_KEY);

        // Should change hotkey without calling moveStake (no stake to move)
        vm.expectEmit(true, true, false, true);
        emit ValidatorHotkeyChanged(VALIDATOR_HOTKEY, NEW_VALIDATOR_HOTKEY);

        vm.prank(owner);
        newDistributor.changeValidatorHotkey(NEW_VALIDATOR_HOTKEY);

        assertEq(newDistributor.validatorHotkey(), NEW_VALIDATOR_HOTKEY);
    }

    function test_RevertWhen_ChangeHotkeyWithoutPublicKey() public {
        // Create new distributor without setting public key
        bytes32[] memory recipients = new bytes32[](1);
        recipients[0] = RECIPIENT1_COLDKEY;
        uint256[] memory proportions = new uint256[](1);
        proportions[0] = 10000;

        Distributor newDistributor = new Distributor(owner, VALIDATOR_HOTKEY, NETUID, recipients, proportions);

        vm.prank(owner);
        vm.expectRevert("Public key not set");
        newDistributor.changeValidatorHotkey(NEW_VALIDATOR_HOTKEY);
    }

    function test_RevertWhen_MoveStakeFails() public {
        // Mock the current stake balance
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(INITIAL_BALANCE)
        );

        // Mock moveStake to return false (failure)
        vm.mockCallRevert(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("moveStake(bytes32,bytes32,uint16,uint16,uint256)")),
                VALIDATOR_HOTKEY,
                NEW_VALIDATOR_HOTKEY,
                NETUID,
                NETUID,
                INITIAL_BALANCE
            ),
            "Move stake failed"
        );

        vm.prank(owner);
        vm.expectRevert("Move stake call failed");
        distributor.changeValidatorHotkey(NEW_VALIDATOR_HOTKEY);
    }

    function test_RevertWhen_NonOwnerChangesHotkey() public {
        vm.prank(nonOwner);
        vm.expectRevert("Caller is not the owner");
        distributor.changeValidatorHotkey(NEW_VALIDATOR_HOTKEY);
    }

    function test_RevertWhen_InvalidHotkeyChange() public {
        vm.prank(owner);
        vm.expectRevert("Invalid hotkey");
        distributor.changeValidatorHotkey(bytes32(0));

        vm.prank(owner);
        vm.expectRevert("Same hotkey");
        distributor.changeValidatorHotkey(VALIDATOR_HOTKEY);
    }

    function test_SetThisSs58PublicKey() public {
        bytes32[] memory recipients = new bytes32[](1);
        recipients[0] = RECIPIENT1_COLDKEY;
        uint256[] memory proportions = new uint256[](1);
        proportions[0] = 10000;

        Distributor newDistributor = new Distributor(owner, VALIDATOR_HOTKEY, NETUID, recipients, proportions);

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(INITIAL_BALANCE)
        );

        vm.expectEmit(true, false, false, true);
        emit PrincipalDetected(INITIAL_BALANCE, INITIAL_BALANCE);

        vm.prank(owner);
        newDistributor.setThisSs58PublicKey(CONTRACT_SS58_KEY);

        assertEq(newDistributor.thisSs58PublicKey(), CONTRACT_SS58_KEY);
        assertEq(newDistributor.getLockedPrincipal(), INITIAL_BALANCE);
        assertEq(newDistributor.previousBalance(), INITIAL_BALANCE);
        assertEq(newDistributor.getCurrentRewardRate(), 0);
        assertEq(newDistributor.getLastPaymentAmount(), 0);
    }

    function test_GetStakedBalance() public view {
        uint256 balance = distributor.getStakedBalance();
        assertEq(balance, INITIAL_BALANCE);
    }

    function test_ExecuteTransfer_FirstExecution_WithRewards() public {
        // Simulate rewards (10 TAO) for first execution
        uint256 rewards = 10e9;
        uint256 newBalance = INITIAL_BALANCE + rewards;

        // Mock the new balance
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(newBalance)
        );

        // Mock transfer calls for each recipient
        uint256 recipient1Amount = (rewards * 6000) / 10000; // 60%
        uint256 recipient2Amount = (rewards * 4000) / 10000; // 40%

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("transferStake(bytes32,bytes32,uint16,uint16,uint256)")),
                RECIPIENT1_COLDKEY,
                VALIDATOR_HOTKEY,
                NETUID,
                NETUID,
                recipient1Amount
            ),
            abi.encode()
        );

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("transferStake(bytes32,bytes32,uint16,uint16,uint256)")),
                RECIPIENT2_COLDKEY,
                VALIDATOR_HOTKEY,
                NETUID,
                NETUID,
                recipient2Amount
            ),
            abi.encode()
        );

        // Fast forward past min interval
        vm.roll(block.number + MIN_BLOCK_INTERVAL + 1);

        // Execute transfer
        vm.expectEmit(true, false, false, true);
        emit StakeTransferred(rewards, newBalance - rewards);

        distributor.executeTransfer();

        // Verify state updates
        assertEq(distributor.previousBalance(), newBalance - rewards);
        assertEq(distributor.lastTransferBlock(), block.number);
        assertEq(distributor.getLastPaymentAmount(), rewards);
        assertGt(distributor.getCurrentRewardRate(), 0); // Should have set a rate
    }

    function test_ExecuteTransfer_PrincipalDetection_RateDoubled() public {
        // First, execute a normal transfer to establish a baseline rate
        uint256 normalRewards = 10e9; // 10 TAO
        uint256 balanceAfterNormal = INITIAL_BALANCE + normalRewards;

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(balanceAfterNormal)
        );

        // Mock transfers for normal execution
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(bytes4(keccak256("transferStake(bytes32,bytes32,uint16,uint16,uint256)"))),
            abi.encode()
        );

        vm.roll(block.number + MIN_BLOCK_INTERVAL + 1);
        distributor.executeTransfer();

        // Now simulate a large balance increase that would more than double the rate
        uint256 principalAddition = 500e9; // 500 TAO added as principal
        uint256 smallRewards = 5e9; // 5 TAO normal rewards
        uint256 newBalance = balanceAfterNormal - normalRewards + principalAddition + smallRewards;

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(newBalance)
        );

        // Should detect principal and use last payment amount instead
        vm.expectEmit(true, false, false, true);
        emit PrincipalDetected(principalAddition + smallRewards, INITIAL_BALANCE + principalAddition + smallRewards);

        vm.roll(block.number + MIN_BLOCK_INTERVAL + 1);
        distributor.executeTransfer();

        // Should have updated principal
        assertEq(distributor.getLockedPrincipal(), INITIAL_BALANCE + principalAddition + smallRewards);
    }

    function test_ExecuteTransfer_NoRewards_UsesLastPayment() public {
        // First execution to set lastPaymentAmount
        uint256 initialRewards = 10e9;
        uint256 balanceAfterFirst = INITIAL_BALANCE + initialRewards;

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(balanceAfterFirst)
        );

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(bytes4(keccak256("transferStake(bytes32,bytes32,uint16,uint16,uint256)"))),
            abi.encode()
        );

        vm.roll(block.number + MIN_BLOCK_INTERVAL + 1);
        distributor.executeTransfer();

        // Now no new rewards - same balance as after first transfer
        uint256 balanceAfterTransfer = balanceAfterFirst - initialRewards;
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(balanceAfterTransfer)
        );

        vm.roll(block.number + MIN_BLOCK_INTERVAL + 1);

        // Should skip transfer since no rewards and no balance above principal
        vm.expectEmit(true, false, false, true);
        emit TransferSkipped("Below existential amount", 0);

        distributor.executeTransfer();
    }

    function test_CanExecuteTransfer() public {
        // Initially can't execute (too soon)
        assertFalse(distributor.canExecuteTransfer());

        // Fast forward past min interval
        vm.roll(block.number + MIN_BLOCK_INTERVAL + 1);

        // Mock sufficient rewards
        uint256 rewards = 2e9; // 2 TAO
        uint256 newBalance = INITIAL_BALANCE + rewards;

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(newBalance)
        );

        assertTrue(distributor.canExecuteTransfer());
    }

    function test_GetNextTransferAmount() public {
        // Simulate rewards (5 TAO)
        uint256 rewards = 5e9;
        uint256 newBalance = INITIAL_BALANCE + rewards;

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(newBalance)
        );

        uint256 transferAmount = distributor.getNextTransferAmount();
        assertEq(transferAmount, rewards);
    }

    function test_GetRecipients() public view {
        assertEq(distributor.getRecipientCount(), 2);

        (bytes32 coldkey1, uint256 proportion1) = distributor.getRecipient(0);
        assertEq(coldkey1, RECIPIENT1_COLDKEY);
        assertEq(proportion1, 6000);

        (bytes32 coldkey2, uint256 proportion2) = distributor.getRecipient(1);
        assertEq(coldkey2, RECIPIENT2_COLDKEY);
        assertEq(proportion2, 4000);
    }

    function test_GetAvailableRewards() public {
        // Mock balance above principal
        uint256 rewards = 50e9;
        uint256 newBalance = INITIAL_BALANCE + rewards;

        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")), VALIDATOR_HOTKEY, CONTRACT_SS58_KEY, NETUID
            ),
            abi.encode(newBalance)
        );

        uint256 availableRewards = distributor.getAvailableRewards();
        assertEq(availableRewards, rewards);
    }

    function test_BlocksUntilNextTransfer() public {
        uint256 blocksLeft = distributor.blocksUntilNextTransfer();
        assertEq(blocksLeft, MIN_BLOCK_INTERVAL);

        vm.roll(block.number + MIN_BLOCK_INTERVAL / 2);
        blocksLeft = distributor.blocksUntilNextTransfer();
        assertEq(blocksLeft, MIN_BLOCK_INTERVAL / 2);

        vm.roll(block.number + MIN_BLOCK_INTERVAL / 2 + 1);
        blocksLeft = distributor.blocksUntilNextTransfer();
        assertEq(blocksLeft, 0);
    }

    function test_ViewFunctions() public view {
        assertEq(distributor.getLockedPrincipal(), INITIAL_BALANCE);
        assertEq(distributor.getCurrentRewardRate(), 0); // No transfers yet
        assertEq(distributor.getLastPaymentAmount(), 0); // No transfers yet
    }
}
