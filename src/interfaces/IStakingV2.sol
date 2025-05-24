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
    function getAlphaStakedValidators(bytes32 hotkey, uint16 netuid)
        external
        view
        returns (bytes32[] memory coldkeys);
    function getTotalAlphaStaked(bytes32 hotkey, uint16 netuid) external view returns (uint256 stakeAlpha);
}
