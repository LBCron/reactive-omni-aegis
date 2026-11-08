// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

import { ISystemContract } from "../lib/reactive-lib-omni/src/interfaces/ISystemContract.sol";
import { IReactive } from "../lib/reactive-lib-omni/src/interfaces/IReactive.sol";
import { AbstractReactive } from "../lib/reactive-lib-omni/src/base/AbstractReactive.sol";

/**
 * @title OmniAegisReactiveGuard
 * @notice Multi-Track Reactive Smart Contract deployed on Reactive Omni (~1s CometBFT blocks, instant finality).
 * @dev Unifies all three Reactive Omni Buildathon tracks in one cohesive, production-grade reactive engine:
 *      - Track 1 ("Every Second Counts"): Watches Base Sepolia (84532, 200ms blocks) and Unichain Sepolia (1301, 1s blocks)
 *        DEX `Sync` / `Swap` events and Lending `HealthFactorUpdated` events. Computes EMA price, high-water-mark drawdown,
 *        and cross-chain Base<->Unichain price gaps inside `react()`, firing sub-second stop-loss, arbitrage, and
 *        collateral top-up callbacks.
 *      - Track 2 ("Set It and Forget It"): Subscribes to Reactive Network's native `Cron100` / `Cron10` ticks on
 *        `0x0000000000000000000000000000000000fffFfF` and `ScheduleRegistered` events to trigger personal recurring DCA
 *        and portfolio rebalance automations without external bots.
 *      - Track 3 ("Reactive Meets AI"): Subscribes to `AIOracleSignal` events from `AIThreatSignalEmitter`, fusing
 *        neural network threat scores with on-chain volatility to trigger preemptive vault protection callbacks.
 */
contract OmniAegisReactiveGuard is AbstractReactive {
    // =========================================================================
    // Chain IDs & Protocol Constants
    // =========================================================================
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint256 public constant REACTIVE_LASNA_CHAIN_ID = 5318007;
    uint256 public constant REACTIVE_MAINNET_CHAIN_ID = 1597;

    /// @notice Legacy system address where Reactive Network validators emit `Cron*` events.
    address public constant LEGACY_SYSTEM_ADDR = 0x0000000000000000000000000000000000fffFfF;

    /// @notice Protocol Cron Topic0 constants from Reactive Omni documentation.
    uint256 public constant CRON10_TOPIC_0 = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;
    uint256 public constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    /// @notice Event Topic0 hashes monitored by OmniAegisReactiveGuard.
    /// `Sync(uint112,uint112)`
    uint256 public constant DEX_SYNC_TOPIC_0 = 0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1;
    /// `HealthFactorUpdated(address,uint256,uint256,uint256,uint256)`
    uint256 public constant HEALTH_FACTOR_TOPIC_0 =
        uint256(keccak256("HealthFactorUpdated(address,uint256,uint256,uint256,uint256)"));
    /// `AIOracleSignal(uint256,address,uint256,uint256,int256,uint8,bytes32,uint256)`
    uint256 public constant AI_ORACLE_SIGNAL_TOPIC_0 =
        uint256(keccak256("AIOracleSignal(uint256,address,uint256,uint256,int256,uint8,bytes32,uint256)"));
    /// `ScheduleRegistered(uint256,address,uint256,uint8,uint256,uint256)`
    uint256 public constant SCHEDULE_REGISTERED_TOPIC_0 =
        uint256(keccak256("ScheduleRegistered(uint256,address,uint256,uint8,uint256,uint256)"));

    uint64 public constant DEFAULT_CALLBACK_GAS_LIMIT = 800_000;
    uint256 public constant EMA_ALPHA_BPS = 3_000; // 30% weight on new observation, 70% on prior EMA

    // =========================================================================
    // Data Structures
    // =========================================================================
    struct PoolSnapshot {
        uint112 reserve0;
        uint112 reserve1;
        uint256 spotPriceWad;
        uint256 emaPriceWad;
        uint256 highWaterMarkPriceWad;
        uint256 drawdownBps;
        uint256 volatilityBps;
        uint256 lastOriginBlock;
        uint256 updatesCount;
    }

    struct RiskConfig {
        uint256 maxDrawdownBps;          // e.g. 500 bps (5.00% drop from high-water mark triggers stop-loss)
        uint256 maxVolatilityBps;        // e.g. 350 bps (3.50% single-block price jump vs EMA)
        uint256 arbSpreadThresholdBps;   // e.g. 150 bps (1.50% Base Sepolia vs Unichain Sepolia spread)
        uint256 minHealthFactorWad;      // e.g. 1.15e18 (triggers collateral top-up)
        uint256 aiRiskThresholdBps;      // e.g. 7000 bps (70.00% neural threat score triggers preemptive shield)
    }

    struct TrackedSchedule {
        uint256 scheduleId;
        uint256 targetChainId;
        address owner;
        uint8 strategyType;
        uint256 amountPerTick;
        bool active;
    }

    error UnauthorizedOwner(address caller);

    event AegisReactionTriggered(
        uint256 indexed reactionId,
        uint256 indexed originChainId,
        uint256 indexed destinationChainId,
        address targetVault,
        string actionName,
        uint256 metricValue,
        uint256 originTxHash
    );

    event SubscriptionsStateChanged(bool paused);

    address public immutable owner;

    /// @notice Origin contracts monitored on Base Sepolia (84532) and Unichain Sepolia (1301).
    address public baseDexPool;
    address public unichainDexPool;
    address public baseLendingMarket;
    address public aiSignalEmitter;

    /// @notice Destination `AegisVaultCallbackReceiver` contracts per chain ID.
    mapping(uint256 => address) public destinationVaults;

    /// @notice Real-time reactive state per origin chain ID.
    mapping(uint256 => PoolSnapshot) public poolSnapshots;

    /// @notice Latest AI risk score per chain ID in basis points.
    mapping(uint256 => uint256) public latestAiRiskScoreBps;

    /// @notice Active personal automation schedules ("Set It and Forget It") tracked by Reactive Omni.
    uint256[] public activeScheduleIds;
    mapping(uint256 => TrackedSchedule) public trackedSchedules;

    RiskConfig public riskConfig;
    bool public subscriptionsPaused;
    uint256 public totalReactions;
    uint256 public totalCallbacksRequested;

    /**
     * @param baseDexPool_ DEX pool on Base Sepolia (84532).
     * @param unichainDexPool_ DEX pool on Unichain Sepolia (1301).
     * @param baseLendingMarket_ Lending market on Base Sepolia (84532).
     * @param aiSignalEmitter_ `AIThreatSignalEmitter` contract address.
     * @param baseVault_ `AegisVaultCallbackReceiver` on Base Sepolia (84532).
     * @param unichainVault_ `AegisVaultCallbackReceiver` on Unichain Sepolia (1301).
     * @param subscribeOnDeploy_ Whether to immediately call `SYSTEM.subscribe` in constructor.
     */
    constructor(
        address baseDexPool_,
        address unichainDexPool_,
        address baseLendingMarket_,
        address aiSignalEmitter_,
        address baseVault_,
        address unichainVault_,
        bool subscribeOnDeploy_
    ) payable {
        owner = msg.sender;
        baseDexPool = baseDexPool_;
        unichainDexPool = unichainDexPool_;
        baseLendingMarket = baseLendingMarket_;
        aiSignalEmitter = aiSignalEmitter_;

        destinationVaults[BASE_SEPOLIA_CHAIN_ID] = baseVault_;
        destinationVaults[UNICHAIN_SEPOLIA_CHAIN_ID] = unichainVault_;

        riskConfig = RiskConfig({
            maxDrawdownBps: 500,        // 5.00% drawdown stop-loss
            maxVolatilityBps: 350,      // 3.50% sudden volatility spike
            arbSpreadThresholdBps: 150, // 1.50% cross-chain arbitrage spread
            minHealthFactorWad: 1.15e18,// 1.15 minimum health factor
            aiRiskThresholdBps: 7_000   // 70.00% neural network threat threshold
        });

        if (subscribeOnDeploy_ && address(SYSTEM).code.length > 0) {
            _subscribeAll();
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert UnauthorizedOwner(msg.sender);
        _;
    }

    // =========================================================================
    // Subscription Lifecycle Management (Reactive Omni Pattern)
    // =========================================================================

    function _subscribeAll() internal {
        // 1. Track 1: Base Sepolia DEX Sync & Lending HealthFactorUpdated
        if (baseDexPool != address(0)) {
            SYSTEM.subscribe(
                BASE_SEPOLIA_CHAIN_ID,
                baseDexPool,
                DEX_SYNC_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        if (baseLendingMarket != address(0)) {
            SYSTEM.subscribe(
                BASE_SEPOLIA_CHAIN_ID,
                baseLendingMarket,
                HEALTH_FACTOR_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }

        // 2. Track 1: Unichain Sepolia DEX Sync
        if (unichainDexPool != address(0)) {
            SYSTEM.subscribe(
                UNICHAIN_SEPOLIA_CHAIN_ID,
                unichainDexPool,
                DEX_SYNC_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }

        // 3. Track 2: Reactive Omni Cron100 & ScheduleRegistered
        SYSTEM.subscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            CRON100_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        if (destinationVaults[BASE_SEPOLIA_CHAIN_ID] != address(0)) {
            SYSTEM.subscribe(
                BASE_SEPOLIA_CHAIN_ID,
                destinationVaults[BASE_SEPOLIA_CHAIN_ID],
                SCHEDULE_REGISTERED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }

        // 4. Track 3: AIThreatSignalEmitter (`AIOracleSignal`)
        if (aiSignalEmitter != address(0)) {
            SYSTEM.subscribe(
                0, // Monitor AI oracle signals emitted on Origin or Reactive chain
                aiSignalEmitter,
                AI_ORACLE_SIGNAL_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function _unsubscribeAll() internal {
        if (baseDexPool != address(0)) {
            SYSTEM.unsubscribe(
                BASE_SEPOLIA_CHAIN_ID,
                baseDexPool,
                DEX_SYNC_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        if (baseLendingMarket != address(0)) {
            SYSTEM.unsubscribe(
                BASE_SEPOLIA_CHAIN_ID,
                baseLendingMarket,
                HEALTH_FACTOR_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        if (unichainDexPool != address(0)) {
            SYSTEM.unsubscribe(
                UNICHAIN_SEPOLIA_CHAIN_ID,
                unichainDexPool,
                DEX_SYNC_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        SYSTEM.unsubscribe(
            block.chainid,
            LEGACY_SYSTEM_ADDR,
            CRON100_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
        if (destinationVaults[BASE_SEPOLIA_CHAIN_ID] != address(0)) {
            SYSTEM.unsubscribe(
                BASE_SEPOLIA_CHAIN_ID,
                destinationVaults[BASE_SEPOLIA_CHAIN_ID],
                SCHEDULE_REGISTERED_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
        if (aiSignalEmitter != address(0)) {
            SYSTEM.unsubscribe(
                0,
                aiSignalEmitter,
                AI_ORACLE_SIGNAL_TOPIC_0,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    function pauseSubscriptions() external onlyOwner {
        if (!subscriptionsPaused) {
            _unsubscribeAll();
            subscriptionsPaused = true;
            emit SubscriptionsStateChanged(true);
        }
    }

    function resumeSubscriptions() external payable onlyOwner {
        if (subscriptionsPaused) {
            _coverDebt();
            _subscribeAll();
            subscriptionsPaused = false;
            emit SubscriptionsStateChanged(false);
        }
    }

    function setDestinationVault(uint256 chainId_, address vault_) external onlyOwner {
        destinationVaults[chainId_] = vault_;
    }

    function updateRiskConfig(RiskConfig calldata newConfig_) external onlyOwner {
        riskConfig = newConfig_;
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    // =========================================================================
    // Core Reactive Entrypoint (`react(LogRecord calldata log_)`)
    // =========================================================================

    /// @inheritdoc IReactive
    function react(LogRecord calldata log_) external onlySystem {
        ++totalReactions;

        if (log_.topic0 == DEX_SYNC_TOPIC_0 && log_.opCode == 1) {
            _handleDexSync(log_.chainId, log_.data, log_.blockNumber, log_.txHash);
        } else if (log_.topic0 == HEALTH_FACTOR_TOPIC_0 && log_.opCode == 3) {
            _handleHealthFactorUpdate(log_.chainId, log_.topic1, log_.topic2, log_.data, log_.txHash);
        } else if (log_.topic0 == AI_ORACLE_SIGNAL_TOPIC_0 && log_.opCode == 3) {
            _handleAIOracleSignal(log_.chainId, log_.topic1, log_.data, log_.txHash);
        } else if (log_.topic0 == SCHEDULE_REGISTERED_TOPIC_0 && log_.opCode == 3) {
            _handleScheduleRegistered(log_.topic1, log_.topic2, log_.data);
        } else if (log_.topic0 == CRON100_TOPIC_0 || log_.topic0 == CRON10_TOPIC_0) {
            _handleCronTick(log_.chainId, log_.data);
        }
        // Non-matching logs intentionally fall through without reverting (Reactive Omni best practice).
    }

    // =========================================================================
    // Track 1: Low-Latency DeFi (Stop-Loss, Volatility Spike & Cross-Chain Arb)
    // =========================================================================

    function _handleDexSync(
        uint256 originChainId_,
        bytes calldata data_,
        uint256 blockNumber_,
        uint256 txHash_
    ) internal {
        (uint112 reserve0, uint112 reserve1) = abi.decode(data_, (uint112, uint112));
        if (reserve0 == 0 || reserve1 == 0) return;

        uint256 spotPriceWad = (uint256(reserve1) * 1e18) / uint256(reserve0);
        PoolSnapshot storage snap = poolSnapshots[originChainId_];

        uint256 prevEma = snap.emaPriceWad == 0 ? spotPriceWad : snap.emaPriceWad;
        snap.emaPriceWad = (spotPriceWad * EMA_ALPHA_BPS + prevEma * (10_000 - EMA_ALPHA_BPS)) / 10_000;

        if (spotPriceWad > snap.highWaterMarkPriceWad) {
            snap.highWaterMarkPriceWad = spotPriceWad;
        }

        uint256 highWater = snap.highWaterMarkPriceWad;
        snap.drawdownBps = highWater > spotPriceWad ? ((highWater - spotPriceWad) * 10_000) / highWater : 0;

        uint256 absDiff = spotPriceWad > prevEma ? (spotPriceWad - prevEma) : (prevEma - spotPriceWad);
        snap.volatilityBps = prevEma > 0 ? (absDiff * 10_000) / prevEma : 0;

        snap.reserve0 = reserve0;
        snap.reserve1 = reserve1;
        snap.spotPriceWad = spotPriceWad;
        snap.lastOriginBlock = blockNumber_;
        snap.updatesCount += 1;

        _checkFlashCrashStopLoss(originChainId_, txHash_);
        _checkCrossChainArbitrage(originChainId_, txHash_);
    }

    function _checkFlashCrashStopLoss(uint256 originChainId_, uint256 originTxHash_) internal {
        address vault = destinationVaults[originChainId_];
        if (vault == address(0)) return;

        PoolSnapshot storage snap = poolSnapshots[originChainId_];
        uint256 drawdownBps = snap.drawdownBps;
        uint256 volatilityBps = snap.volatilityBps;

        if (drawdownBps >= riskConfig.maxDrawdownBps || volatilityBps >= riskConfig.maxVolatilityBps) {
            uint8 reason = drawdownBps >= riskConfig.maxDrawdownBps ? 1 : 2;
            uint256 metric = drawdownBps >= riskConfig.maxDrawdownBps ? drawdownBps : volatilityBps;
            bytes memory payload = abi.encodeWithSignature(
                "executeEmergencyStopLoss(address,uint8,uint256,uint256,uint256)",
                address(0),
                reason,
                snap.spotPriceWad,
                metric,
                originTxHash_
            );
            _dispatchCallback(originChainId_, vault, payload, originChainId_, "EMERGENCY_STOP_LOSS", metric, originTxHash_);
        }
    }

    function _checkCrossChainArbitrage(uint256 originChainId_, uint256 originTxHash_) internal {
        uint256 basePrice = poolSnapshots[BASE_SEPOLIA_CHAIN_ID].spotPriceWad;
        uint256 uniPrice = poolSnapshots[UNICHAIN_SEPOLIA_CHAIN_ID].spotPriceWad;
        if (basePrice == 0 || uniPrice == 0) return;

        uint256 diff = basePrice > uniPrice ? (basePrice - uniPrice) : (uniPrice - basePrice);
        uint256 minPrice = basePrice < uniPrice ? basePrice : uniPrice;
        uint256 spreadBps = (diff * 10_000) / minPrice;

        if (spreadBps >= riskConfig.arbSpreadThresholdBps) {
            uint256 targetChain = basePrice <= uniPrice ? BASE_SEPOLIA_CHAIN_ID : UNICHAIN_SEPOLIA_CHAIN_ID;
            address arbVault = destinationVaults[targetChain];
            if (arbVault == address(0)) {
                targetChain = BASE_SEPOLIA_CHAIN_ID;
                arbVault = destinationVaults[BASE_SEPOLIA_CHAIN_ID];
            }
            if (arbVault != address(0)) {
                bytes memory arbPayload = abi.encodeWithSignature(
                    "executeCrossChainArbitrage(address,uint256,uint256,uint256,uint256,uint256)",
                    address(0),
                    originChainId_,
                    basePrice,
                    uniPrice,
                    spreadBps,
                    originTxHash_
                );
                _dispatchCallback(
                    targetChain,
                    arbVault,
                    arbPayload,
                    originChainId_,
                    "CROSS_CHAIN_ARBITRAGE",
                    spreadBps,
                    originTxHash_
                );
            }
        }
    }

    function _handleHealthFactorUpdate(
        uint256 originChainId_,
        uint256 topic1_,
        uint256 topic2_,
        bytes calldata data_,
        uint256 txHash_
    ) internal {
        (uint256 healthFactorWad, uint256 collateralUsd, uint256 debtUsd) =
            abi.decode(data_, (uint256, uint256, uint256));

        if (healthFactorWad < riskConfig.minHealthFactorWad) {
            address vault = destinationVaults[originChainId_];
            if (vault == address(0)) return;

            uint256 requiredTopUp = collateralUsd > 0 ? collateralUsd / 5 : (debtUsd / 4);
            bytes memory payload = abi.encodeWithSignature(
                "executeCollateralTopUp(address,address,uint256,uint256,uint256,uint256)",
                address(0),
                address(uint160(topic1_)),
                topic2_,
                healthFactorWad,
                requiredTopUp,
                txHash_
            );
            _dispatchCallback(
                originChainId_,
                vault,
                payload,
                originChainId_,
                "COLLATERAL_TOP_UP",
                healthFactorWad,
                txHash_
            );
        }
    }

    // =========================================================================
    // Track 2: "Set It and Forget It" (Personal Automations & Cron Scheduling)
    // =========================================================================

    function _handleScheduleRegistered(
        uint256 topic1_,
        uint256 topic2_,
        bytes calldata data_
    ) internal {
        uint256 scheduleId = topic1_;
        address scheduleOwner = address(uint160(topic2_));
        (uint256 targetChainId, uint8 strategyType, uint256 amountPerTick, ) =
            abi.decode(data_, (uint256, uint8, uint256, uint256));

        if (!trackedSchedules[scheduleId].active) {
            activeScheduleIds.push(scheduleId);
        }
        trackedSchedules[scheduleId] = TrackedSchedule({
            scheduleId: scheduleId,
            targetChainId: targetChainId,
            owner: scheduleOwner,
            strategyType: strategyType,
            amountPerTick: amountPerTick,
            active: true
        });
    }

    function _handleCronTick(uint256 originChainId_, bytes calldata data_) internal {
        uint256 cronBlock = data_.length >= 32 ? abi.decode(data_, (uint256)) : block.number;
        uint256 len = activeScheduleIds.length;

        for (uint256 i = 0; i < len; ++i) {
            TrackedSchedule memory sched = trackedSchedules[activeScheduleIds[i]];
            if (!sched.active) continue;

            address vault = destinationVaults[sched.targetChainId];
            if (vault == address(0)) continue;

            uint256 refPrice = poolSnapshots[sched.targetChainId].spotPriceWad;
            if (refPrice == 0) {
                refPrice = 2_500e18; // Default reference price if no Sync observed yet
            }

            bytes memory payload = abi.encodeWithSignature(
                "executeScheduledAutomation(address,uint256,uint256,uint256)",
                address(0),
                sched.scheduleId,
                refPrice,
                cronBlock
            );
            _dispatchCallback(
                sched.targetChainId,
                vault,
                payload,
                originChainId_,
                "SCHEDULED_DCA_AUTOMATION",
                sched.scheduleId,
                cronBlock
            );
        }
    }

    // =========================================================================
    // Track 3: "Reactive Meets AI" (Neural Network Threat Fusion)
    // =========================================================================

    function _computeCompositeRiskBps(uint256 targetChainId_, uint256 riskScoreBps_) internal view returns (uint256) {
        PoolSnapshot storage snap = poolSnapshots[targetChainId_];
        uint256 onChainSignalBps = snap.drawdownBps > snap.volatilityBps ? snap.drawdownBps * 10 : snap.volatilityBps * 10;
        if (onChainSignalBps > 10_000) onChainSignalBps = 10_000;
        return (riskScoreBps_ * 60 + onChainSignalBps * 40) / 100;
    }

    function _handleAIOracleSignal(
        uint256 originChainId_,
        uint256 targetChainId_,
        bytes calldata data_,
        uint256 txHash_
    ) internal {
        (
            uint256 riskScoreBps,
            uint256 predictedVolatilityBps,
            ,
            uint8 recommendedAction,
            bytes32 modelCommitHash,
        ) = abi.decode(data_, (uint256, uint256, int256, uint8, bytes32, uint256));

        latestAiRiskScoreBps[targetChainId_] = riskScoreBps;

        if (
            riskScoreBps >= riskConfig.aiRiskThresholdBps ||
            _computeCompositeRiskBps(targetChainId_, riskScoreBps) >= riskConfig.aiRiskThresholdBps
        ) {
            address vault = destinationVaults[targetChainId_];
            if (vault == address(0)) return;

            bytes memory payload = abi.encodeWithSignature(
                "executeAIShieldAction(address,uint256,uint256,uint8,bytes32,uint256)",
                address(0),
                riskScoreBps,
                predictedVolatilityBps,
                recommendedAction,
                modelCommitHash,
                txHash_
            );
            _dispatchCallback(
                targetChainId_,
                vault,
                payload,
                originChainId_,
                "AI_SHIELD_PREEMPTIVE_EXIT",
                riskScoreBps,
                txHash_
            );
        }
    }

    // =========================================================================
    // Internal Callback Dispatcher (Reactive Omni V_1_0 + Event Compatibility)
    // =========================================================================

    function _dispatchCallback(
        uint256 destinationChainId_,
        address recipient_,
        bytes memory payload_,
        uint256 originChainId_,
        string memory actionName_,
        uint256 metricValue_,
        uint256 originTxHash_
    ) internal {
        ++totalCallbacksRequested;

        // 1. Emit standard IReactive `Callback` event
        emit Callback(destinationChainId_, recipient_, DEFAULT_CALLBACK_GAS_LIMIT, payload_);

        // 2. Request callback via Reactive Omni `SYSTEM.requestCallbackV_1_0`
        if (address(SYSTEM).code.length > 0) {
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: destinationChainId_,
                    recipient: recipient_,
                    gasLimit: DEFAULT_CALLBACK_GAS_LIMIT,
                    payload: payload_
                })
            );
        }

        emit AegisReactionTriggered(
            totalCallbacksRequested,
            originChainId_,
            destinationChainId_,
            recipient_,
            actionName_,
            metricValue_,
            originTxHash_
        );
    }

    function getActiveSchedulesCount() external view returns (uint256) {
        return activeScheduleIds.length;
    }
}
