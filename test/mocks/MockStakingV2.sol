// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

contract MockStakingV2 {
    mapping(bytes32 => mapping(bytes32 => mapping(uint16 => uint256))) private stakes;
    
    // Track transfer calls
    bool public transferStakeCalled;
    bytes32 public lastDestinationColdkey;
    bytes32 public lastHotkey;
    uint16 public lastOriginNetuid;
    uint16 public lastDestinationNetuid;
    uint256 public lastTransferAmount;
    
    bool private shouldFailTransfer;

    function setStake(bytes32 hotkey, bytes32 coldkey, uint16 netuid, uint256 amount) external {
        stakes[hotkey][coldkey][netuid] = amount;
    }

    function getStake(bytes32 hotkey, bytes32 coldkey, uint16 netuid) external view returns (uint256) {
        return stakes[hotkey][coldkey][netuid];
    }

    function transferStake(
        bytes32 destinationColdkey,
        bytes32 hotkey,
        uint16 originNetuid,
        uint16 destinationNetuid,
        uint256 amountAlpha
    ) external {
        if (shouldFailTransfer) {
            revert("Mock transfer failure");
        }
        
        // Record the call
        transferStakeCalled = true;
        lastDestinationColdkey = destinationColdkey;
        lastHotkey = hotkey;
        lastOriginNetuid = originNetuid;
        lastDestinationNetuid = destinationNetuid;
        lastTransferAmount = amountAlpha;
    }

    function setShouldFailTransfer(bool _shouldFail) external {
        shouldFailTransfer = _shouldFail;
    }

    function resetTransferTracking() external {
        transferStakeCalled = false;
        lastDestinationColdkey = bytes32(0);
        lastHotkey = bytes32(0);
        lastOriginNetuid = 0;
        lastDestinationNetuid = 0;
        lastTransferAmount = 0;
    }

    // Add receive function to handle payable fallback warning
    receive() external payable {}

    // Fallback to handle any other calls
    fallback() external payable {
        // Do nothing - just don't revert
    }
} 