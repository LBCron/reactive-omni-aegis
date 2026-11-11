// SPDX-License-Identifier: MIT

pragma solidity >=0.8.20;

import { IPayable } from "../lib/reactive-lib-omni/src/interfaces/IPayable.sol";
import { IReactive } from "../lib/reactive-lib-omni/src/interfaces/IReactive.sol";
import { ISystemContract } from "../lib/reactive-lib-omni/src/interfaces/ISystemContract.sol";
import { AbstractPayer } from "../lib/reactive-lib-omni/src/base/AbstractPayer.sol";
import { AbstractCallback } from "../lib/reactive-lib-omni/src/base/AbstractCallback.sol";

import { OmniAegisReactiveGuard } from "../contracts/OmniAegisReactiveGuard.sol";
import { AegisVaultCallbackReceiver } from "../contracts/AegisVaultCallbackReceiver.sol";
import { AIThreatSignalEmitter } from "../contracts/AIThreatSignalEmitter.sol";
import { MockOmniSystemContract } from "../contracts/mocks/MockOmniSystemContract.sol";
import { MockCallbackProxy } from "../contracts/mocks/MockCallbackProxy.sol";
import { MockDEXPool } from "../contracts/mocks/MockDEXPool.sol";
import { MockLendingMarket } from "../contracts/mocks/MockLendingMarket.sol";

interface Vm {
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function deal(address who, uint256 newBalance) external;
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function warp(uint256 newTimestamp) external;
    function roll(uint256 newHeight) external;
    function expectRevert(bytes calldata revertData) external;
    function expectRevert(bytes4 revertSelector) external;
    function expectRevert() external;
}

contract OmniAegisTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant OMNI_SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant LEGACY_CRON_ADDR = 0x0000000000000000000000000000000000fffFfF;
    address internal constant BASE_SEPOLIA_CALLBACK_PROXY = 0x476F44b11F5C942c58f4c8E3d0300E5710743585;
    address internal constant UNICHAIN_SEPOLIA_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    MockOmniSystemContract internal systemContract;
    MockCallbackProxy internal baseCallbackProxy;
    MockCallbackProxy internal unichainCallbackProxy;

    MockDEXPool internal basePool;
    MockDEXPool internal unichainPool;
    MockLendingMarket internal lendingMarket;
    AIThreatSignalEmitter internal aiEmitter;

    AegisVaultCallbackReceiver internal baseVault;
    AegisVaultCallbackReceiver internal unichainVault;
    OmniAegisReactiveGuard internal reactiveGuard;

    address internal alice = address(0xA11CE);
    address internal attacker = address(0xBAD);

    function setUp() public {
        vm.warp(1_762_600_000);
        vm.roll(1_000);

        // 1. Etch MockOmniSystemContract at Reactive Omni's canonical `0x8888...8888` address
        MockOmniSystemContract sysImpl = new MockOmniSystemContract();
        vm.etch(OMNI_SYSTEM_ADDR, address(sysImpl).code);
        systemContract = MockOmniSystemContract(payable(OMNI_SYSTEM_ADDR));

        // 2. Etch MockCallbackProxy at canonical Base Sepolia & Unichain Sepolia proxy addresses
        MockCallbackProxy proxyImpl = new MockCallbackProxy();
        vm.etch(BASE_SEPOLIA_CALLBACK_PROXY, address(proxyImpl).code);
        vm.etch(UNICHAIN_SEPOLIA_CALLBACK_PROXY, address(proxyImpl).code);
        baseCallbackProxy = MockCallbackProxy(payable(BASE_SEPOLIA_CALLBACK_PROXY));
        unichainCallbackProxy = MockCallbackProxy(payable(UNICHAIN_SEPOLIA_CALLBACK_PROXY));

        // 3. Deploy Origin Market Mocks & AI Threat Signal Emitter
        basePool = new MockDEXPool(100e18, 250_000e18);      // 2,500 USDC per WETH
        unichainPool = new MockDEXPool(100e18, 250_000e18);  // 2,500 USDC per WETH
        lendingMarket = new MockLendingMarket();
        aiEmitter = new AIThreatSignalEmitter(address(this));

        // 4. Deploy Destination Vaults on Base Sepolia & Unichain Sepolia
        baseVault = new AegisVaultCallbackReceiver{ value: 1 ether }(
            IPayable(payable(BASE_SEPOLIA_CALLBACK_PROXY)),
            address(0), // Will authorize reactiveGuard right after deployment
            100 ether,  // 100 WETH risk asset
            250_000 ether, // 250,000 USDC stable reserve
            60          // 60s minimum emergency cooldown using block.timestamp
        );

        unichainVault = new AegisVaultCallbackReceiver{ value: 1 ether }(
            IPayable(payable(UNICHAIN_SEPOLIA_CALLBACK_PROXY)),
            address(0),
            100 ether,
            250_000 ether,
            60
        );

        // 5. Deploy OmniAegisReactiveGuard on Reactive Omni and wire destination vaults
        reactiveGuard = new OmniAegisReactiveGuard{ value: 1 ether }(
            address(basePool),
            address(unichainPool),
            address(lendingMarket),
            address(aiEmitter),
            address(baseVault),
            address(unichainVault),
            true
        );

        baseVault.setAuthorizedReactiveSender(address(reactiveGuard), true);
        unichainVault.setAuthorizedReactiveSender(address(reactiveGuard), true);
    }

    function test_01_ConstructorSubscribesAllSixStreamsOnReactiveOmni() public view {
        uint256 activeSubs = systemContract.getActiveSubscriptionsCount(address(reactiveGuard));
        require(activeSubs == 6, "Expected 6 active subscriptions on Reactive Omni SYSTEM");
    }

    function test_02_RejectsUnauthorizedReactCaller() public {
        IReactive.LogRecord memory fakeLog = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(basePool),
            topic0: reactiveGuard.DEX_SYNC_TOPIC_0(),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(uint112(100e18), uint112(200_000e18)),
            blockNumber: 1001,
            opCode: 1,
            blockHash: 111,
            txHash: 222,
            logIndex: 0
        });

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, attacker, OMNI_SYSTEM_ADDR)
        );
        reactiveGuard.react(fakeLog);
    }

    function test_03_Track1_DexSyncFlashCrashTriggersEmergencyStopLoss() public {
        // Step 1: Normal Sync at 2,500 USDC/WETH establishes high-water mark
        IReactive.LogRecord memory normalSync = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(basePool),
            topic0: reactiveGuard.DEX_SYNC_TOPIC_0(),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(uint112(100e18), uint112(250_000e18)),
            blockNumber: 1001,
            opCode: 1,
            blockHash: 0xAA01,
            txHash: 0xBB01,
            logIndex: 0
        });
        systemContract.deliverLog(address(reactiveGuard), normalSync);
        require(systemContract.getCallbackQueueLength() == 0, "No callback on healthy Sync");

        // Step 2: Flash crash on Base Sepolia to 2,200 USDC/WETH (12% drawdown = 1200 bps >= 500 bps threshold)
        IReactive.LogRecord memory crashSync = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(basePool),
            topic0: reactiveGuard.DEX_SYNC_TOPIC_0(),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(uint112(100e18), uint112(220_000e18)),
            blockNumber: 1002,
            opCode: 1,
            blockHash: 0xAA02,
            txHash: 0xBB02,
            logIndex: 1
        });
        systemContract.deliverLog(address(reactiveGuard), crashSync);

        require(systemContract.getCallbackQueueLength() == 1, "Expected 1 emergency stop-loss callback");
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = systemContract.getQueuedCallback(0);
        require(cb.chainId == BASE_SEPOLIA_CHAIN_ID, "Destination must be Base Sepolia");
        require(cb.recipient == address(baseVault), "Recipient must be Base Vault");

        // Step 3: Relay callback through Base Sepolia Callback Proxy (injects reactiveGuard address)
        baseCallbackProxy.dispatch(address(reactiveGuard), cb.recipient, cb.gasLimit, cb.payload);

        require(baseVault.emergencyCircuitBreakerActive(), "Circuit breaker must be active");
        require(baseVault.riskAssetBalance() == 50 ether, "50% of risk asset must be liquidated");
        require(baseVault.stableReserveBalance() == 360_000 ether, "Stable reserve must increase by 110,000 USDC");
        require(baseVault.getReceiptsCount() == 1, "Execution receipt must be recorded");
    }

    function test_04_Track1_CrossChainArbitrageBetweenBaseAndUnichain() public {
        // 1. Base Sepolia Sync at 2,500 USDC/WETH
        IReactive.LogRecord memory baseSync = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(basePool),
            topic0: reactiveGuard.DEX_SYNC_TOPIC_0(),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(uint112(100e18), uint112(250_000e18)),
            blockNumber: 1010,
            opCode: 1,
            blockHash: 0xCC01,
            txHash: 0xDD01,
            logIndex: 0
        });
        systemContract.deliverLog(address(reactiveGuard), baseSync);

        // 2. Unichain Sepolia Sync at 2,560 USDC/WETH (2.40% spread = 240 bps >= 150 bps arb threshold)
        IReactive.LogRecord memory uniSync = IReactive.LogRecord({
            chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
            contractAddress: address(unichainPool),
            topic0: reactiveGuard.DEX_SYNC_TOPIC_0(),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(uint112(100e18), uint112(256_000e18)),
            blockNumber: 505,
            opCode: 1,
            blockHash: 0xCC02,
            txHash: 0xDD02,
            logIndex: 0
        });
        systemContract.deliverLog(address(reactiveGuard), uniSync);

        require(systemContract.getCallbackQueueLength() == 1, "Expected 1 cross-chain arbitrage callback");
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = systemContract.getQueuedCallback(0);
        require(cb.chainId == BASE_SEPOLIA_CHAIN_ID, "Routes arb callback to lower-priced chain (Base Sepolia)");

        uint256 reserveBefore = baseVault.stableReserveBalance();
        baseCallbackProxy.dispatch(address(reactiveGuard), cb.recipient, cb.gasLimit, cb.payload);
        uint256 reserveAfter = baseVault.stableReserveBalance();

        require(reserveAfter > reserveBefore, "Cross-chain arbitrage must capture positive spread profit");
    }

    function test_05_Track1_LendingHealthFactorDropTriggersCollateralTopUp() public {
        uint256 posId = baseVault.registerLendingPosition(
            alice,
            10 ether,  // collateral
            18_000 ether, // debt
            1.35e18,   // initial health factor
            5 ether    // auto-top-up reserve
        );

        // Emit HealthFactorUpdated with healthFactor = 1.08e18 (< 1.15e18 threshold)
        IReactive.LogRecord memory hfLog = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(lendingMarket),
            topic0: reactiveGuard.HEALTH_FACTOR_TOPIC_0(),
            topic1: uint256(uint160(alice)),
            topic2: posId,
            topic3: 0,
            data: abi.encode(uint256(1.08e18), uint256(10 ether), uint256(18_000 ether)),
            blockNumber: 1020,
            opCode: 3,
            blockHash: 0xEE01,
            txHash: 0xFF01,
            logIndex: 2
        });
        systemContract.deliverLog(address(reactiveGuard), hfLog);

        require(systemContract.getCallbackQueueLength() == 1, "Expected 1 collateral top-up callback");
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = systemContract.getQueuedCallback(0);
        baseCallbackProxy.dispatch(address(reactiveGuard), cb.recipient, cb.gasLimit, cb.payload);

        (, uint256 collateralAfter, , uint256 hfAfter, uint256 reserveAfter, uint256 topUpCount, ) =
            baseVault.positions(posId);
        require(collateralAfter == 12 ether, "Collateral must be topped up by 20% (2 ETH)");
        require(reserveAfter == 3 ether, "Auto-top-up reserve must be decremented by 2 ETH");
        require(hfAfter == 1.43e18, "Health factor must be restored to 1.43 WAD");
        require(topUpCount == 1, "Top-up count must be 1");
    }

    function test_06_Track2_SetItAndForgetIt_CronDrivenDcaScheduleAnd200msBlockSafety() public {
        // 1. User registers a recurring DCA buy schedule (1,000 USDC every 300 seconds)
        vm.prank(alice);
        uint256 schedId = baseVault.registerAutomationSchedule(
            AegisVaultCallbackReceiver.StrategyType.RECURRING_DCA_BUY,
            1_000 ether,
            300, // 300 seconds interval (timestamp-based, immune to Base Sepolia 200ms block rate)
            2_000e18,
            3_000e18
        );

        // 2. Reactive Omni receives the ScheduleRegistered log
        IReactive.LogRecord memory regLog = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(baseVault),
            topic0: reactiveGuard.SCHEDULE_REGISTERED_TOPIC_0(),
            topic1: schedId,
            topic2: uint256(uint160(alice)),
            topic3: 0,
            data: abi.encode(BASE_SEPOLIA_CHAIN_ID, uint8(0), uint256(1_000 ether), uint256(300)),
            blockNumber: 1030,
            opCode: 3,
            blockHash: 0x1111,
            txHash: 0x2222,
            logIndex: 0
        });
        systemContract.deliverLog(address(reactiveGuard), regLog);
        require(reactiveGuard.getActiveSchedulesCount() == 1, "Schedule must be tracked by Reactive Guard");

        // 3. Reactive Omni fires a Cron100 tick from LEGACY_CRON_ADDR (0x0000...fffFfF)
        IReactive.LogRecord memory cronLog = IReactive.LogRecord({
            chainId: 5318007,
            contractAddress: LEGACY_CRON_ADDR,
            topic0: reactiveGuard.CRON100_TOPIC_0(),
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: abi.encode(uint256(1100)),
            blockNumber: 1100,
            opCode: 1,
            blockHash: 0x3333,
            txHash: 0x4444,
            logIndex: 0
        });
        systemContract.deliverLog(address(reactiveGuard), cronLog);

        require(systemContract.getCallbackQueueLength() == 1, "Cron tick must queue DCA callback");
        ISystemContract.CallbackConfiguration_V_1_0 memory cb1 = systemContract.getQueuedCallback(0);
        baseCallbackProxy.dispatch(address(reactiveGuard), cb1.recipient, cb1.gasLimit, cb1.payload);

        // 4. Advance Base Sepolia by 500 blocks (only 100 seconds at 200ms/block -> still < 300s interval!)
        vm.roll(1600);
        vm.warp(block.timestamp + 100);
        systemContract.deliverLog(address(reactiveGuard), cronLog);
        ISystemContract.CallbackConfiguration_V_1_0 memory cbEarly = systemContract.getQueuedCallback(1);

        vm.expectRevert();
        baseCallbackProxy.dispatch(address(reactiveGuard), cbEarly.recipient, cbEarly.gasLimit, cbEarly.payload);

        // 5. Advance timestamp by another 205 seconds (total +305s >= 300s interval) -> DCA succeeds!
        vm.warp(block.timestamp + 205);
        baseCallbackProxy.dispatch(address(reactiveGuard), cbEarly.recipient, cbEarly.gasLimit, cbEarly.payload);

        (, , , , , , , , uint256 totalExecuted, uint256 execCount, ) = baseVault.schedules(schedId);
        require(execCount == 2, "DCA schedule must have executed 2 tranches after timestamp cooldown");
        require(totalExecuted == 2_000 ether, "Total executed DCA must be 2,000 USDC");
    }

    function test_07_Track3_ReactiveMeetsAI_NeuralSignalTriggersPreemptiveShield() public {
        bytes32 modelCommit = keccak256("AegisTCN-v1.0-weights-sha256:9f86d081884c7d659a2feaa0c55ad015");

        uint256 seqId = aiEmitter.publishSignal(
            BASE_SEPOLIA_CHAIN_ID,
            address(basePool),
            8_400, // 84.00% neural threat score (>= 70.00% threshold)
            620,   // 6.20% predicted short-horizon volatility
            -480,  // -4.80% predicted flash dump return
            uint8(AIThreatSignalEmitter.RecommendedAction.EMERGENCY_STOP_LOSS),
            modelCommit
        );
        require(seqId == 1, "Signal sequence ID must be 1");

        IReactive.LogRecord memory aiLog = IReactive.LogRecord({
            chainId: BASE_SEPOLIA_CHAIN_ID,
            contractAddress: address(aiEmitter),
            topic0: reactiveGuard.AI_ORACLE_SIGNAL_TOPIC_0(),
            topic1: BASE_SEPOLIA_CHAIN_ID,
            topic2: uint256(uint160(address(basePool))),
            topic3: 0,
            data: abi.encode(
                uint256(8_400),
                uint256(620),
                int256(-480),
                uint8(AIThreatSignalEmitter.RecommendedAction.EMERGENCY_STOP_LOSS),
                modelCommit,
                block.timestamp
            ),
            blockNumber: 1050,
            opCode: 3,
            blockHash: 0x7777,
            txHash: 0x8888,
            logIndex: 0
        });
        systemContract.deliverLog(address(reactiveGuard), aiLog);

        require(systemContract.getCallbackQueueLength() == 1, "AI threat signal must trigger preemptive callback");
        ISystemContract.CallbackConfiguration_V_1_0 memory cb = systemContract.getQueuedCallback(0);
        baseCallbackProxy.dispatch(address(reactiveGuard), cb.recipient, cb.gasLimit, cb.payload);

        require(baseVault.riskAssetBalance() == 60 ether, "AI Shield must preemptively shift 40% of risk assets");
        require(baseVault.emergencyCircuitBreakerActive(), "Circuit breaker must be armed by AI emergency action");

        AegisVaultCallbackReceiver.ExecutionReceipt memory r = baseVault.getReceipt(0);
        require(r.metadataHash == modelCommit, "Receipt must preserve neural network modelCommitHash");
    }

    function test_08_CallbackAuthenticationRejectsSpoofedCallers() public {
        // 1. Direct call bypassing CallbackProxy must revert with NotAuthorized
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractPayer.NotAuthorized.selector,
                attacker,
                BASE_SEPOLIA_CALLBACK_PROXY
            )
        );
        baseVault.executeEmergencyStopLoss(address(reactiveGuard), 1, 2_000e18, 800, 0x1234);

        // 2. Call through legitimate CallbackProxy but with unapproved reactive sender must revert
        bytes memory badPayload = abi.encodeWithSignature(
            "executeEmergencyStopLoss(address,uint8,uint256,uint256,uint256)",
            address(0),
            uint8(1),
            uint256(2_000e18),
            uint256(800),
            uint256(0x1234)
        );
        vm.expectRevert();
        baseCallbackProxy.dispatch(attacker, address(baseVault), 800_000, badPayload);
    }

    function test_09_PauseAndResumeSubscriptionsWithDebtSettlement() public {
        reactiveGuard.pauseSubscriptions();
        require(reactiveGuard.subscriptionsPaused(), "Subscriptions must be marked paused");
        require(
            systemContract.getActiveSubscriptionsCount(address(reactiveGuard)) == 0,
            "All 6 subscriptions must be inactive when paused"
        );

        // Simulate 0.25 lREACT network debt accrued on SYSTEM
        systemContract.setDebt(address(reactiveGuard), 0.25 ether);
        uint256 sysBalanceBefore = OMNI_SYSTEM_ADDR.balance;

        reactiveGuard.resumeSubscriptions();
        require(!reactiveGuard.subscriptionsPaused(), "Subscriptions must be resumed");
        require(
            OMNI_SYSTEM_ADDR.balance == sysBalanceBefore + 0.25 ether,
            "resumeSubscriptions must settle debt to SYSTEM"
        );
        require(
            systemContract.getActiveSubscriptionsCount(address(reactiveGuard)) == 6,
            "All 6 subscriptions must be re-registered"
        );
    }
}
