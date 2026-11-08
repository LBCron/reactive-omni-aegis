// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

import { IPayable } from "../lib/reactive-lib-omni/src/interfaces/IPayable.sol";
import { AbstractCallback } from "../lib/reactive-lib-omni/src/base/AbstractCallback.sol";

/**
 * @title AegisVaultCallbackReceiver
 * @notice Destination vault and automation executor on Base Sepolia (84532) & Unichain Sepolia (1301).
 * @dev Inherits official `AbstractCallback` from `reactive-lib-omni`.
 *      Enforces dual authentication (`onlyServiceProvider` + `onlyCallbackSender(reactiveSender)`) and
 *      uses `block.timestamp` (never `block.number`) for all cooldowns, intervals, and circuit-breakers
 *      in compliance with Base Sepolia's 200ms Denim block time rules.
 */
contract AegisVaultCallbackReceiver is AbstractCallback {
    enum ActionType {
        EMERGENCY_STOP_LOSS,
        CROSS_CHAIN_ARBITRAGE,
        COLLATERAL_TOP_UP,
        SCHEDULED_DCA_AUTOMATION,
        AI_SHIELD_PREEMPTIVE_EXIT
    }

    enum StrategyType {
        RECURRING_DCA_BUY,
        RECURRING_DCA_SELL,
        TRAILING_TAKE_PROFIT,
        AUTO_REBALANCE_50_50
    }

    struct LendingPosition {
        address user;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 healthFactorWad;
        uint256 autoTopUpReserve;
        uint256 topUpCount;
        uint256 lastTopUpTimestamp;
    }

    struct AutomationSchedule {
        uint256 scheduleId;
        address owner;
        StrategyType strategyType;
        uint256 amountPerTick;
        uint256 intervalSeconds;      // Timestamp-based cooldown (safe for Base Sepolia 200ms blocks)
        uint256 lastExecutedTimestamp;
        uint256 priceFloorWad;
        uint256 priceCeilingWad;
        uint256 totalExecutedAmount;
        uint256 executionCount;
        bool active;
    }

    struct ExecutionReceipt {
        uint256 receiptId;
        ActionType actionType;
        address reactiveSender;
        uint256 referencePriceWad;
        uint256 metricBps;
        uint256 amountMoved;
        uint256 originTxHash;
        uint256 executedAtTimestamp;
        bytes32 metadataHash;
    }

    error UnauthorizedOwner(address caller);
    error CooldownActive(uint256 nextAvailableTimestamp, uint256 currentTimestamp);
    error ScheduleInactive(uint256 scheduleId);
    error InsufficientPositionReserve(uint256 positionId, uint256 requiredAmount, uint256 availableAmount);

    event AegisCallbackExecuted(
        uint256 indexed receiptId,
        ActionType indexed actionType,
        address indexed reactiveSender,
        uint256 referencePriceWad,
        uint256 metricBps,
        uint256 amountMoved,
        uint256 originTxHash,
        uint256 executedAtTimestamp
    );

    event ScheduleRegistered(
        uint256 indexed scheduleId,
        address indexed owner,
        uint256 targetChainId,
        uint8 strategyType,
        uint256 amountPerTick,
        uint256 intervalSeconds
    );

    event PositionRegistered(
        uint256 indexed positionId,
        address indexed user,
        uint256 collateralAmount,
        uint256 debtAmount,
        uint256 autoTopUpReserve
    );

    event ReactiveSenderAuthorized(address indexed reactiveContract, bool authorized);

    address public immutable owner;

    /// @notice Vault portfolio state (simulated WETH risk asset + USDC stable reserve in WAD 1e18 units).
    uint256 public riskAssetBalance;
    uint256 public stableReserveBalance;
    bool public emergencyCircuitBreakerActive;

    /// @notice Timestamp-based cooldown between emergency vault actions (safe for 200ms Base Sepolia blocks).
    uint256 public minActionCooldownSeconds;
    uint256 public lastEmergencyActionTimestamp;

    uint256 public totalPositions;
    uint256 public totalSchedules;

    mapping(address => bool) public authorizedReactiveSenders;
    mapping(uint256 => LendingPosition) public positions;
    mapping(uint256 => AutomationSchedule) public schedules;
    ExecutionReceipt[] public receipts;

    /**
     * @param callbackProxy_ Official Reactive Network Callback Proxy on this chain
     *        (Base Sepolia: 0x476F44b11F5C942c58f4c8E3d0300E5710743585,
     *         Unichain Sepolia: 0x775c9B990ADe401060B78D0e98684eEf8d2466C1).
     * @param callbackSender_ Address of `OmniAegisReactiveGuard` on Reactive Omni.
     * @param initialRiskAsset_ Initial vault risk asset exposure (e.g., 100 ether).
     * @param initialStableReserve_ Initial vault stable reserve (e.g., 250_000 ether).
     * @param minActionCooldownSeconds_ Minimum seconds between emergency rebalances using block.timestamp.
     */
    constructor(
        IPayable callbackProxy_,
        address callbackSender_,
        uint256 initialRiskAsset_,
        uint256 initialStableReserve_,
        uint256 minActionCooldownSeconds_
    ) payable AbstractCallback(callbackProxy_, callbackSender_) {
        owner = msg.sender;
        if (callbackSender_ != address(0)) {
            authorizedReactiveSenders[callbackSender_] = true;
        }
        riskAssetBalance = initialRiskAsset_;
        stableReserveBalance = initialStableReserve_;
        minActionCooldownSeconds = minActionCooldownSeconds_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedOwner(msg.sender);
        _;
    }

    /// @dev Extends `AbstractCallback._onlyCallbackSender` so the deployer can link `OmniAegisReactiveGuard`
    ///      either at construction time or post-deployment via `setAuthorizedReactiveSender`.
    function _onlyCallbackSender(address callbackSender_) internal view override {
        if (callbackSender_ != _CALLBACK_SENDER && !authorizedReactiveSenders[callbackSender_]) {
            revert CallbackNotAuthorized(callbackSender_, _CALLBACK_SENDER);
        }
    }

    function setAuthorizedReactiveSender(address reactiveContract_, bool authorized_) external onlyOwner {
        authorizedReactiveSenders[reactiveContract_] = authorized_;
        emit ReactiveSenderAuthorized(reactiveContract_, authorized_);
    }

    function setMinActionCooldownSeconds(uint256 cooldownSeconds_) external onlyOwner {
        minActionCooldownSeconds = cooldownSeconds_;
    }

    function resetCircuitBreaker() external onlyOwner {
        emergencyCircuitBreakerActive = false;
    }

    /// @notice Exposes internal `_coverDebt()` from `AbstractPayer` as recommended in Reactive Omni docs.
    function coverDebt() external {
        _coverDebt();
    }

    // =========================================================================
    // User Registration Helpers (Track 1 Lending Shield & Track 2 Personal DCA)
    // =========================================================================

    function registerLendingPosition(
        address user_,
        uint256 collateralAmount_,
        uint256 debtAmount_,
        uint256 initialHealthFactorWad_,
        uint256 autoTopUpReserve_
    ) external returns (uint256 positionId) {
        positionId = ++totalPositions;
        positions[positionId] = LendingPosition({
            user: user_,
            collateralAmount: collateralAmount_,
            debtAmount: debtAmount_,
            healthFactorWad: initialHealthFactorWad_,
            autoTopUpReserve: autoTopUpReserve_,
            topUpCount: 0,
            lastTopUpTimestamp: 0
        });
        emit PositionRegistered(positionId, user_, collateralAmount_, debtAmount_, autoTopUpReserve_);
    }

    function registerAutomationSchedule(
        StrategyType strategyType_,
        uint256 amountPerTick_,
        uint256 intervalSeconds_,
        uint256 priceFloorWad_,
        uint256 priceCeilingWad_
    ) external returns (uint256 scheduleId) {
        scheduleId = ++totalSchedules;
        schedules[scheduleId] = AutomationSchedule({
            scheduleId: scheduleId,
            owner: msg.sender,
            strategyType: strategyType_,
            amountPerTick: amountPerTick_,
            intervalSeconds: intervalSeconds_,
            lastExecutedTimestamp: 0,
            priceFloorWad: priceFloorWad_,
            priceCeilingWad: priceCeilingWad_,
            totalExecutedAmount: 0,
            executionCount: 0,
            active: true
        });
        emit ScheduleRegistered(
            scheduleId,
            msg.sender,
            block.chainid,
            uint8(strategyType_),
            amountPerTick_,
            intervalSeconds_
        );
    }

    // =========================================================================
    // Authenticated Reactive Callback Entrypoints
    // Note: First parameter `reactiveSender` is overwritten by the Reactive
    // Callback Proxy with the address of `OmniAegisReactiveGuard`.
    // =========================================================================

    /**
     * @notice Track 1 ("Every Second Counts"): Sub-second emergency stop-loss execution on flash crash.
     */
    function executeEmergencyStopLoss(
        address reactiveSender,
        uint8 reason,
        uint256 triggerPriceWad,
        uint256 drawdownBps,
        uint256 originTxHash
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) returns (uint256 receiptId) {
        if (
            lastEmergencyActionTimestamp != 0 &&
            block.timestamp < lastEmergencyActionTimestamp + minActionCooldownSeconds
        ) {
            revert CooldownActive(lastEmergencyActionTimestamp + minActionCooldownSeconds, block.timestamp);
        }

        lastEmergencyActionTimestamp = block.timestamp;
        emergencyCircuitBreakerActive = true;

        // De-risk 50% of volatile risk asset into stable reserve at triggerPriceWad
        uint256 amountToLiquidate = riskAssetBalance / 2;
        uint256 stableProceeds = (amountToLiquidate * triggerPriceWad) / 1e18;
        riskAssetBalance -= amountToLiquidate;
        stableReserveBalance += stableProceeds;

        receiptId = _recordReceipt(
            ActionType.EMERGENCY_STOP_LOSS,
            reactiveSender,
            triggerPriceWad,
            drawdownBps,
            amountToLiquidate,
            originTxHash,
            bytes32(uint256(reason))
        );
    }

    /**
     * @notice Track 1 ("Every Second Counts"): Cross-chain arbitrage / liquidity rebalance between Base Sepolia & Unichain Sepolia.
     */
    function executeCrossChainArbitrage(
        address reactiveSender,
        uint256 originChainId,
        uint256 basePriceWad,
        uint256 unichainPriceWad,
        uint256 spreadBps,
        uint256 originTxHash
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) returns (uint256 receiptId) {
        uint256 arbNotional = stableReserveBalance / 10; // Allocate 10% of stable reserve to capture spread
        uint256 referencePrice = basePriceWad < unichainPriceWad ? basePriceWad : unichainPriceWad;

        if (arbNotional > 0 && referencePrice > 0) {
            // Simulate atomic spread capture profit credited to stableReserveBalance
            uint256 capturedProfit = (arbNotional * spreadBps) / 10_000;
            stableReserveBalance += capturedProfit;
        }

        receiptId = _recordReceipt(
            ActionType.CROSS_CHAIN_ARBITRAGE,
            reactiveSender,
            referencePrice,
            spreadBps,
            arbNotional,
            originTxHash,
            bytes32(originChainId)
        );
    }

    /**
     * @notice Track 1 ("Every Second Counts"): Instant collateral top-up when lending health factor drops below threshold.
     */
    function executeCollateralTopUp(
        address reactiveSender,
        address /* user */,
        uint256 positionId,
        uint256 healthFactorWad,
        uint256 topUpAmount,
        uint256 originTxHash
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) returns (uint256 receiptId) {
        LendingPosition storage pos = positions[positionId];
        if (pos.autoTopUpReserve < topUpAmount) {
            revert InsufficientPositionReserve(positionId, topUpAmount, pos.autoTopUpReserve);
        }

        pos.autoTopUpReserve -= topUpAmount;
        pos.collateralAmount += topUpAmount;
        pos.healthFactorWad = healthFactorWad + 350000000000000000; // Restores +0.35 WAD health buffer
        pos.topUpCount += 1;
        pos.lastTopUpTimestamp = block.timestamp;

        receiptId = _recordReceipt(
            ActionType.COLLATERAL_TOP_UP,
            reactiveSender,
            pos.healthFactorWad,
            0,
            topUpAmount,
            originTxHash,
            bytes32(positionId)
        );
    }

    /**
     * @notice Track 2 ("Set It and Forget It"): Automated recurring DCA & range rebalance triggered by Reactive Cron.
     */
    function executeScheduledAutomation(
        address reactiveSender,
        uint256 scheduleId,
        uint256 referencePriceWad,
        uint256 cronBlockNumber
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) returns (uint256 receiptId) {
        AutomationSchedule storage sched = schedules[scheduleId];
        if (!sched.active) revert ScheduleInactive(scheduleId);

        if (
            sched.lastExecutedTimestamp != 0 &&
            block.timestamp < sched.lastExecutedTimestamp + sched.intervalSeconds
        ) {
            revert CooldownActive(sched.lastExecutedTimestamp + sched.intervalSeconds, block.timestamp);
        }

        sched.lastExecutedTimestamp = block.timestamp;
        sched.totalExecutedAmount += sched.amountPerTick;
        sched.executionCount += 1;

        if (sched.strategyType == StrategyType.RECURRING_DCA_BUY && stableReserveBalance >= sched.amountPerTick) {
            stableReserveBalance -= sched.amountPerTick;
            uint256 boughtRisk = referencePriceWad > 0 ? (sched.amountPerTick * 1e18) / referencePriceWad : 0;
            riskAssetBalance += boughtRisk;
        } else if (sched.strategyType == StrategyType.RECURRING_DCA_SELL && riskAssetBalance >= sched.amountPerTick) {
            riskAssetBalance -= sched.amountPerTick;
            uint256 soldProceeds = (sched.amountPerTick * referencePriceWad) / 1e18;
            stableReserveBalance += soldProceeds;
        }

        receiptId = _recordReceipt(
            ActionType.SCHEDULED_DCA_AUTOMATION,
            reactiveSender,
            referencePriceWad,
            sched.executionCount,
            sched.amountPerTick,
            cronBlockNumber,
            bytes32(scheduleId)
        );
    }

    /**
     * @notice Track 3 ("Reactive Meets AI"): Neural network preemptive shield action when AI threat score breaches threshold.
     */
    function executeAIShieldAction(
        address reactiveSender,
        uint256 riskScoreBps,
        uint256 predictedVolatilityBps,
        uint8 recommendedAction,
        bytes32 modelCommitHash,
        uint256 originTxHash
    ) external onlyServiceProvider onlyCallbackSender(reactiveSender) returns (uint256 receiptId) {
        // Preemptively shift a proportional fraction of riskAssetBalance (scaled by riskScoreBps) to stable reserve
        uint256 shiftBps = riskScoreBps > 5_000 ? 4_000 : 2_000; // 40% shift on high risk, 20% on moderate risk
        uint256 amountToShift = (riskAssetBalance * shiftBps) / 10_000;
        riskAssetBalance -= amountToShift;
        // Mark preemptive shield active if recommendedAction == EMERGENCY_STOP_LOSS (2)
        if (recommendedAction == 2) {
            emergencyCircuitBreakerActive = true;
        }

        receiptId = _recordReceipt(
            ActionType.AI_SHIELD_PREEMPTIVE_EXIT,
            reactiveSender,
            predictedVolatilityBps,
            riskScoreBps,
            amountToShift,
            originTxHash,
            modelCommitHash
        );
    }

    function _recordReceipt(
        ActionType actionType_,
        address reactiveSender_,
        uint256 referencePriceWad_,
        uint256 metricBps_,
        uint256 amountMoved_,
        uint256 originTxHash_,
        bytes32 metadataHash_
    ) internal returns (uint256 receiptId) {
        receiptId = receipts.length + 1;
        receipts.push(
            ExecutionReceipt({
                receiptId: receiptId,
                actionType: actionType_,
                reactiveSender: reactiveSender_,
                referencePriceWad: referencePriceWad_,
                metricBps: metricBps_,
                amountMoved: amountMoved_,
                originTxHash: originTxHash_,
                executedAtTimestamp: block.timestamp,
                metadataHash: metadataHash_
            })
        );

        emit AegisCallbackExecuted(
            receiptId,
            actionType_,
            reactiveSender_,
            referencePriceWad_,
            metricBps_,
            amountMoved_,
            originTxHash_,
            block.timestamp
        );
    }

    function getReceiptsCount() external view returns (uint256) {
        return receipts.length;
    }

    function getReceipt(uint256 index_) external view returns (ExecutionReceipt memory) {
        return receipts[index_];
    }
}
