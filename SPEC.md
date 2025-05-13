
## Full Solution Specification: EVM-Managed Subnet Owner Operations

**Version:** 1.0
**Objective:** To create a secure and partially automated system for managing a Subtensor subnet owner's coldkey operations (primarily stake management and APY distribution) using EVM smart contracts and precompiles, governed by a multi-signature wallet with a veto mechanism.

**1. Core Requirements Addressed:**

*   **R1: Multi-sig Wallet (Veto Model):** A multi-signature wallet where one owner proposes actions, and other owners have a period to veto. If not sufficiently vetoed, the action becomes executable. This is the primary control mechanism.
*   **R2: Automatic Recurring APY Stake Transfer:** Periodically, the APY (yield) earned by the multi-sig's coldkey should be calculated and distributed as stake to pre-configured destination coldkeys according to specified ratios. This process must account for manual stake movements to accurately identify true APY.
*   **R3: Configurable Distribution Schedule:** The frequency of APY distribution (e.g., daily, weekly) needs to be manageable.
*   **R4: Manual Stake Transfer Support (Veto Model):** The multi-sig wallet itself must be able to initiate manual stake transfers to arbitrary coldkeys, subject to the same proposal-veto process.

**2. System Architecture & Components:**

The system comprises the following interconnected components:

*   **Component A: `MultiSigWalletWithVeto.sol` (The Governor)**
    *   **Primary Role:** Acts as the ultimate decision-maker and executor. Its EVM address, when mapped to an SS58 address by the Subtensor runtime, **is the Subnet Owner's Coldkey**.
    *   **Functionality:** Implements the M-of-N ownership model with a "propose-then-veto" mechanism for all actions it undertakes.
        *   **Proposals:** Any owner can propose:
            *   External calls (e.g., to precompiles, to the `StakeDistributor`).
            *   Internal administrative changes (managing owners, veto parameters of the MultiSig itself).
        *   **Veto Period:** A configurable duration during which other owners can cast vetos.
        *   **Veto Quorum:** A configurable number of vetos required to cancel a proposal.
        *   **Execution:** If a proposal is not sufficiently vetoed within the period, it becomes executable.
    *   **Interactions:**
        *   Executes stake transfers by calling `IStakingV2.transferStake()`.
        *   Executes other Subtensor operations by calling relevant precompiles (e.g., `ISubnet.*`).
        *   Owns and manages the `StakeDistributor` contract by calling its administrative functions.

*   **Component B: `StakeDistributor.sol` (The APY Logic Engine)**
    *   **Primary Role:** Manages the configuration and calculation logic for APY distribution. It does *not* hold funds or execute state-changing Subtensor operations directly.
    *   **Ownership:** Owned exclusively by the `MultiSigWalletWithVeto.sol` contract.
    *   **Functionality:**
        *   **Configuration:** Stores:
            *   The MultiSig's coldkey (bytes32) and its associated hotkey (bytes32) on a specific `netuid`.
            *   A list of `DistributionTarget`s (destination coldkey + distribution ratio).
            *   The `lastKnownStakeBalanceRao` of the MultiSig's coldkey (to differentiate APY from manual transfers).
            *   The `minDistributionIntervalSeconds` to control APY cycle frequency.
        *   **APY Calculation (`calculateApyDistribution()` - view):**
            *   Fetches current stake of the MultiSig's coldkey using `IStakingV2.getStake()`.
            *   Calculates `apyEarnedRao = currentStake - lastKnownStakeBalanceRao`.
            *   Determines the `amountRao` for each `DistributionTarget` based on its ratio.
            *   Returns a list of `TransferOperation` structs (destination, amount) for the MultiSig to execute.
        *   **State Update (`confirmApyDistributionExecuted()` - ownerOnly):** Called by the MultiSig *after* it has executed the APY distribution transfers. Updates `lastKnownStakeBalanceRao` and `lastDistributionTimestamp`.
        *   **Manual Adjustment (`reportManualStakeChange()` - ownerOnly):** Called by the MultiSig *after* it has executed a manual stake transfer (not related to APY). Updates `lastKnownStakeBalanceRao` to reflect the change.
    *   **Interactions:**
        *   Read-only calls to `IStakingV2.getStake()`.
        *   Is called by the `MultiSigWalletWithVeto` for configuration and state updates.
        *   Is called by the `Keeper` (view function) to get APY distribution plans.

*   **Component C: Subtensor Precompile Interfaces (`IStakingV2.sol`, `ISubnet.sol`, etc.)**
    *   **Primary Role:** Solidity interfaces that define how smart contracts can call the Subtensor runtime's precompiled functions.
    *   **Functionality:** Provide the function signatures and data types for interacting with staking, metagraph, and subnet management functionalities.
    *   **Interactions:** Used by `MultiSigWalletWithVeto` (for execution) and `StakeDistributor` (for read-only queries like `getStake`).

*   **Component D: Keeper (Off-Chain Automation Agent)**
    *   **Primary Role:** Triggers the periodic APY distribution process. This component is *not* a smart contract.
    *   **Functionality:**
        *   Monitors time to respect the `minDistributionIntervalSeconds`.
        *   Calls `StakeDistributor.calculateApyDistribution()` to get the plan.
        *   For each `TransferOperation` in the plan, constructs and submits a proposal to the `MultiSigWalletWithVeto` to call `IStakingV2.transferStake()`.
        *   After the MultiSig executes these transfers, the Keeper gathers confirmation data (total distributed, new actual stake) and submits a proposal to the MultiSig to call `StakeDistributor.confirmApyDistributionExecuted()`.
    *   **Implementation:** Can be a script (Python, Node.js) run on a server, a cron job, or initially, a manual process performed by one of the MultiSig owners.
    *   **Interactions:**
        *   Reads from `StakeDistributor`.
        *   Submits proposals to `MultiSigWalletWithVeto`.

**3. Detailed Workflows:**

**3.1. System Setup & Initialization:**

1.  **Deploy `MultiSigWalletWithVeto.sol`:**
    *   Input: Initial owners, `vetoesRequiredToCancel`, `vetoDuration`.
    *   Output: Deployed MultiSig contract address. This address's corresponding SS58 is the subnet owner coldkey.
2.  **Fund & Register Coldkey:** The SS58 address corresponding to the deployed MultiSig contract must be funded with TAO and appropriately registered/staked on the Subtensor network under an `associatedHotkeyBytes32` on the target `netuid`.
3.  **Deploy `StakeDistributor.sol`:**
    *   Input: Address of the `IStakingV2` precompile, address of the deployed `MultiSigWalletWithVeto` (as owner).
    *   Output: Deployed `StakeDistributor` contract address.
4.  **Initialize `StakeDistributor` (via MultiSig Proposal):**
    *   An owner of `MultiSigWalletWithVeto` proposes a transaction targeting `StakeDistributor.initialize()`.
    *   `initialize()` arguments include: `multisigColdkeyBytes32` (from MultiSig), `associatedHotkeyBytes32`, `netuid`, initial `DistributionTarget[]`, current `lastKnownStakeBalanceRao` (queried from `IStakingV2.getStake()`), and `minDistributionIntervalSeconds`.
    *   The proposal goes through the veto process. If executed by `MultiSigWalletWithVeto`, `StakeDistributor` is configured.

**3.2. Automatic Recurring APY Distribution (R2, R3):**

1.  **Trigger (Keeper):** The Keeper checks if `minDistributionIntervalSeconds` has passed since `StakeDistributor.lastDistributionTimestamp`.
2.  **Calculate (Keeper & StakeDistributor):**
    *   Keeper calls `StakeDistributor.calculateApyDistribution()` (view function).
    *   `StakeDistributor` fetches current stake, calculates APY earned (`currentStake - lastKnownStakeBalanceRao`), and generates `TransferOperation[]` based on configured ratios.
3.  **Propose Transfers (Keeper to MultiSig):**
    *   For each `TransferOperation`, the Keeper (acting as a MultiSig owner or authorized entity) proposes a transaction to `MultiSigWalletWithVeto` to call `IStakingV2.transferStake(op.destinationColdkey, associatedHotkeyBytes32, netuid, netuid, op.amountRao)`.
4.  **Approve & Execute Transfers (MultiSig):**
    *   `MultiSigWalletWithVeto` owners review and potentially veto these `transferStake` proposals.
    *   If not vetoed, proposals become executable after `vetoDuration`, and `MultiSigWalletWithVeto` executes them.
5.  **Confirm & Update State (Keeper to StakeDistributor via MultiSig):**
    *   After transfers are executed, the Keeper:
        *   Queries the *actual* new stake of `multisigColdkeyBytes32`.
        *   Calculates the total TAO *actually* distributed.
        *   Proposes a transaction to `MultiSigWalletWithVeto` to call `StakeDistributor.confirmApyDistributionExecuted(totalDistributed, actualNewStake)`.
    *   `MultiSigWalletWithVeto` (after veto process) executes this call.
    *   `StakeDistributor` updates its `lastKnownStakeBalanceRao` and `lastDistributionTimestamp`.

**3.3. Manual Stake Transfer (R4, using R1 model):**

1.  **Initiate (MultiSig Owner):** An owner of `MultiSigWalletWithVeto` proposes a transaction targeting `IStakingV2.transferStake()` with the desired manual destination coldkey and amount.
    *   `target`: `IStakingV2_PRECOMPILE_ADDRESS`.
    *   `data`: `abi.encodeWithSelector(IStakingV2.transferStake.selector, manualDestinationColdkeyBytes32, associatedHotkeyBytes32, netuid, netuid, manualAmountRao)`.
2.  **Approve & Execute Transfer (MultiSig):**
    *   Standard veto process within `MultiSigWalletWithVeto`.
    *   If not vetoed and executable, `MultiSigWalletWithVeto` calls `IStakingV2.transferStake()`.
3.  **Report Manual Change (MultiSig Owner to StakeDistributor via MultiSig - CRITICAL):**
    *   **After** the manual transfer is successfully executed, an owner *must* propose a transaction to `MultiSigWalletWithVeto` to call `StakeDistributor.reportManualStakeChange(amountChangeRao)`.
    *   `amountChangeRao` is negative if stake was moved *out* of the MultiSig's coldkey, positive if *in*.
    *   This ensures `StakeDistributor.lastKnownStakeBalanceRao` is accurate for future APY calculations.
4.  **Approve & Execute Report (MultiSig):** Standard veto process. `StakeDistributor` state is updated.

**4. Contract Details (High-Level - refer to previous detailed specs for full function signatures):**

*   **`MultiSigWalletWithVeto.sol`:**
    *   State: `owners`, `isOwner`, `vetoesRequiredToCancel`, `vetoDuration`, `proposals[]`, `proposalVetoes[][]`.
    *   Functions: `constructor`, `proposeTransaction`, `vetoTransaction`, `executeTransaction`, internal admin helpers (`_addOwner`, etc.), view functions.
*   **`StakeDistributor.sol`:**
    *   State: `owner` (MultiSig addr), `multisigColdkeyBytes32`, `associatedHotkeyBytes32`, `netuid`, `distributionTargets[]`, `lastKnownStakeBalanceRao`, `lastDistributionTimestamp`, `minDistributionIntervalSeconds`.
    *   Functions: `constructor`, `initialize` (ownerOnly), `updateDistributionTargets` (ownerOnly), `reportManualStakeChange` (ownerOnly), `calculateApyDistribution` (view), `confirmApyDistributionExecuted` (ownerOnly), view functions.

**5. Addressing Specific Requirements from Summary:**

*   **"multi-sig wallet, regardless of anything else"**: Addressed by `MultiSigWalletWithVeto.sol` being the central controller.
*   **"automatic recurring alpha stake transfer of the delta from APY (excluding any transfers) to configured coldkeys with specified ratios"**:
    *   "Automatic recurring": Handled by the off-chain Keeper triggering the cycle.
    *   "delta from APY (excluding any transfers)": Handled by `StakeDistributor`'s logic of `currentStake - lastKnownStakeBalanceRao` and the `reportManualStakeChange` function ensuring `lastKnownStakeBalanceRao` is correct.
    *   "configured coldkeys with specified ratios": Stored in `StakeDistributor.distributionTargets`.
    *   "Example: wallet has 10000 alpha... do stake transfer 0.5 alpha to each": The `calculateApyDistribution` logic will determine the 1 alpha APY, then split it (0.5 + 0.5) for the `transferStake` operations proposed to the MultiSig.
*   **"daily schedule? weekly? each epoch? not sure here"**:
    *   The `StakeDistributor.minDistributionIntervalSeconds` provides a minimum.
    *   The actual schedule (daily, weekly, etc.) is implemented by the **Keeper's triggering logic**.
*   **"manual transfer support via either: one of the multi-sig wallets initiates a transfer and the others need to veto within N days to cancel it or it's auto-approved"**: This is precisely the model implemented by `MultiSigWalletWithVeto.sol` for all its actions, including manual calls to `IStakingV2.transferStake()`.
*   **"manual multi-sig 2/3 vote for transfers but no time delay"**: This is *not* the primary model chosen for this spec (which uses veto). If this strict M/N without delay is absolutely required *additionally*, it would necessitate a different multi-sig contract or a separate set of functions within the chosen multi-sig that bypasses the veto-specific logic and uses a direct M/N confirmation count. For simplicity and to align with the veto preference, this spec sticks to the veto model for all actions.

**6. Precompile Usage:**

*   `IStakingV2.transferStake()`: Used for both APY distribution and manual transfers, executed by `MultiSigWalletWithVeto`.
*   `IStakingV2.getStake()`: Used by `StakeDistributor` to get current balances for APY calculation.
*   `ISubnet.*` / `IMetagraph.*`: Can be called by `MultiSigWalletWithVeto` for any other subnet/metagraph management tasks, following the same proposal-veto process.

**7. Security & Trust:**

*   The `MultiSigWalletWithVeto` is the root of trust on the EVM side. Its security is paramount.
*   The `StakeDistributor` is trusted to perform calculations correctly but cannot move funds; it only proposes plans or updates its state based on MultiSig actions.
*   The Keeper is trusted to trigger the process and submit valid proposals. A malicious keeper could spam proposals, but cannot execute them or steal funds.
*   Correctness of `lastKnownStakeBalanceRao` in `StakeDistributor` is vital and relies on the MultiSig owners diligently calling `reportManualStakeChange` after any non-APY stake movements they perform.

This comprehensive specification should now cover the entire desired solution, detailing how each component contributes to meeting the overall requirements.