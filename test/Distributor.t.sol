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
    bytes32 public constant RECIPIENT1_COLDKEY = bytes32(uint256(2));
    bytes32 public constant RECIPIENT2_COLDKEY = bytes32(uint256(3));
    bytes32 public constant CONTRACT_SS58_KEY = bytes32(uint256(4));
    uint16 public constant NETUID = 1;
    uint256 public constant INITIAL_BALANCE = 1000e9; // 1000 TAO
    uint256 public constant MIN_BLOCK_INTERVAL = 7200; // 1 day in blocks
    uint256 public constant EXISTENTIAL_AMOUNT = 1e9; // 1 TAO
    uint256 public constant FALLBACK_AMOUNT = 100e9; // 100 TAO

    event StakeTransferred(uint256 totalAmount, uint256 newBalance);
    event RecipientTransfer(bytes32 indexed coldkey, uint256 amount, uint256 proportion);
    event TransferSkipped(string reason, uint256 calculatedAmount);
    event PrincipalDetected(uint256 amount, uint256 totalPrincipal);
    event RecipientsUpdated(uint256 recipientCount);

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
        distributor = new Distributor(
            owner,
            VALIDATOR_HOTKEY,
            NETUID,
            recipients,
            proportions
        );

        // Set the SS58 public key and mock initial balance
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")),
                VALIDATOR_HOTKEY,
                CONTRACT_SS58_KEY,
                NETUID
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
        new Distributor(
            owner,
            VALIDATOR_HOTKEY,
            NETUID,
            recipients,
            proportions
        );

        // Array length mismatch
        uint256[] memory wrongProportions = new uint256[](2);
        wrongProportions[0] = 6000;
        wrongProportions[1] = 4000;
        
        vm.expectRevert("Array length mismatch");
        new Distributor(
            owner,
            VALIDATOR_HOTKEY,
            NETUID,
            recipients,
            wrongProportions
        );
    }

    function test_SetThisSs58PublicKey() public {
        bytes32[] memory recipients = new bytes32[](1);
        recipients[0] = RECIPIENT1_COLDKEY;
        uint256[] memory proportions = new uint256[](1);
        proportions[0] = 10000;

        Distributor newDistributor = new Distributor(
            owner,
            VALIDATOR_HOTKEY,
            NETUID,
            recipients,
            proportions
        );
        
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")),
                VALIDATOR_HOTKEY,
                CONTRACT_SS58_KEY,
                NETUID
            ),
            abi.encode(INITIAL_BALANCE)
        );

        vm.expectEmit(true, false, false, true);
        emit PrincipalDetected(INITIAL_BALANCE, INITIAL_BALANCE);
        
        vm.prank(owner);
        newDistributor.setThisSs58PublicKey(CONTRACT_SS58_KEY);
        
        assertEq(newDistributor.thisSs58PublicKey(), CONTRACT_SS58_KEY);
        assertEq(newDistributor.principalLocked(), INITIAL_BALANCE);
        assertEq(newDistributor.previousBalance(), INITIAL_BALANCE);
    }

    function test_GetStakedBalance() public {
        uint256 balance = distributor.getStakedBalance();
        assertEq(balance, INITIAL_BALANCE);
    }

    function test_ExecuteTransfer_WithRewards() public {
        // Simulate rewards (10 TAO)
        uint256 rewards = 10e9;
        uint256 newBalance = INITIAL_BALANCE + rewards;
        
        // Mock the new balance
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")),
                VALIDATOR_HOTKEY,
                CONTRACT_SS58_KEY,
                NETUID
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
    }

    function test_ExecuteTransfer_ExcessiveRewards_UsesFallback() public {
        // Simulate excessive rewards (>1% of principal)
        uint256 excessiveRewards = (INITIAL_BALANCE * 2) / 100; // 2%
        uint256 newBalance = INITIAL_BALANCE + excessiveRewards;
        
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")),
                VALIDATOR_HOTKEY,
                CONTRACT_SS58_KEY,
                NETUID
            ),
            abi.encode(newBalance)
        );

        // Mock transfer calls for fallback amount
        uint256 recipient1Amount = (FALLBACK_AMOUNT * 6000) / 10000;
        uint256 recipient2Amount = (FALLBACK_AMOUNT * 4000) / 10000;

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

        vm.roll(block.number + MIN_BLOCK_INTERVAL + 1);
        distributor.executeTransfer();

        uint256 expectedNewBalance = newBalance - FALLBACK_AMOUNT;
        assertEq(distributor.previousBalance(), expectedNewBalance);
    }

    function test_ExecuteTransfer_NoRewards_UsesFallback() public {
        // No rewards - same balance
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")),
                VALIDATOR_HOTKEY,
                CONTRACT_SS58_KEY,
                NETUID
            ),
            abi.encode(INITIAL_BALANCE)
        );

        // Mock transfer calls for fallback amount
        uint256 recipient1Amount = (FALLBACK_AMOUNT * 6000) / 10000;
        uint256 recipient2Amount = (FALLBACK_AMOUNT * 4000) / 10000;

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

        vm.roll(block.number + MIN_BLOCK_INTERVAL + 1);
        distributor.executeTransfer();
    }

    function test_DetectNewPrincipal() public {
        // Simulate large stake addition (>10% of principal)
        uint256 newPrincipal = (INITIAL_BALANCE * 15) / 100; // 15%
        uint256 newBalance = INITIAL_BALANCE + newPrincipal;
        
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")),
                VALIDATOR_HOTKEY,
                CONTRACT_SS58_KEY,
                NETUID
            ),
            abi.encode(newBalance)
        );

        vm.expectEmit(true, false, false, true);
        emit PrincipalDetected(newPrincipal, INITIAL_BALANCE + newPrincipal);

        distributor.updatePrincipal();
        
        assertEq(distributor.principalLocked(), INITIAL_BALANCE + newPrincipal);
        assertEq(distributor.previousBalance(), newBalance);
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
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")),
                VALIDATOR_HOTKEY,
                CONTRACT_SS58_KEY,
                NETUID
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
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")),
                VALIDATOR_HOTKEY,
                CONTRACT_SS58_KEY,
                NETUID
            ),
            abi.encode(newBalance)
        );

        uint256 transferAmount = distributor.getNextTransferAmount();
        assertEq(transferAmount, rewards);
    }

    function test_GetRecipients() public {
        assertEq(distributor.getRecipientCount(), 2);
        
        (bytes32 coldkey1, uint256 proportion1) = distributor.getRecipient(0);
        assertEq(coldkey1, RECIPIENT1_COLDKEY);
        assertEq(proportion1, 6000);
        
        (bytes32 coldkey2, uint256 proportion2) = distributor.getRecipient(1);
        assertEq(coldkey2, RECIPIENT2_COLDKEY);
        assertEq(proportion2, 4000);
    }

    function test_UpdateRecipients() public {
        bytes32[] memory newRecipients = new bytes32[](1);
        newRecipients[0] = bytes32(uint256(999));
        uint256[] memory newProportions = new uint256[](1);
        newProportions[0] = 10000;

        vm.expectEmit(true, false, false, true);
        emit RecipientsUpdated(1);

        vm.prank(owner);
        distributor.updateRecipients(newRecipients, newProportions);

        assertEq(distributor.getRecipientCount(), 1);
        (bytes32 coldkey, uint256 proportion) = distributor.getRecipient(0);
        assertEq(coldkey, bytes32(uint256(999)));
        assertEq(proportion, 10000);
    }

    function test_RevertWhen_NonOwnerUpdatesRecipients() public {
        bytes32[] memory newRecipients = new bytes32[](1);
        newRecipients[0] = bytes32(uint256(999));
        uint256[] memory newProportions = new uint256[](1);
        newProportions[0] = 10000;

        vm.prank(nonOwner);
        vm.expectRevert("Caller is not the owner");
        distributor.updateRecipients(newRecipients, newProportions);
    }

    function test_GetAvailableRewards() public {
        // Mock balance above principal
        uint256 rewards = 50e9;
        uint256 newBalance = INITIAL_BALANCE + rewards;
        
        vm.mockCall(
            address(0x808),
            abi.encodeWithSelector(
                bytes4(keccak256("getStake(bytes32,bytes32,uint16)")),
                VALIDATOR_HOTKEY,
                CONTRACT_SS58_KEY,
                NETUID
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
} 