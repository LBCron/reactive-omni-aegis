/**
 * Reactive Omni Aegis — Full-Loop EVM Bytecode Execution Test Suite
 * =================================================================
 * Executes compiled Solidity EVM bytecode (`out/solc/*.bin`) inside `@ethereumjs/vm`
 * with `MockOmniSystemContract` etched at Reactive Omni's canonical `0x8888...8888`
 * address and `MockCallbackProxy` etched at Base Sepolia (`0x476F...3585`) &
 * Unichain Sepolia (`0x775c...66C1`).
 */

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { subprocess } = require("node:child_process");
const { ethers } = require("ethers");
const { createVM } = require("@ethereumjs/vm");
const { createAddressFromString, Account, hexToBytes, bytesToHex } = require("@ethereumjs/util");

const OMNI_SYSTEM_ADDR = "0x8888888888888888888888888888888888888888";
const LEGACY_CRON_ADDR = "0x0000000000000000000000000000000000fffFfF";
const BASE_CALLBACK_PROXY = "0x476F44b11F5C942c58f4c8E3d0300E5710743585";
const UNICHAIN_CALLBACK_PROXY = "0x775c9B990ADe401060B78D0e98684eEf8d2466C1";

const BASE_SEPOLIA_CHAIN_ID = 84532n;
const UNICHAIN_SEPOLIA_CHAIN_ID = 1301n;
const REACTIVE_LASNA_CHAIN_ID = 5318007n;

const DEPLOYER = "0x958cbC9378c75cf158e5B19845E7f004B5f8c3f9";
const ALICE = "0x00000000000000000000000000000000000A11CE";
const ATTACKER = "0x0000000000000000000000000000000000000BAD";

function loadArtifact(prefix) {
  const outDir = path.join(__dirname, "..", "out", "solc");
  const abi = JSON.parse(fs.readFileSync(path.join(outDir, `${prefix}.abi`), "utf8"));
  const bin = fs.readFileSync(path.join(outDir, `${prefix}.bin`), "utf8").trim();
  return { iface: new ethers.Interface(abi), bin };
}

class OmniEvmHarness {
  constructor(vm) {
    this.vm = vm;
    this.timestamp = 1762600000n;
    this.blockNumber = 1000n;
  }

  static async create() {
    const vm = await createVM();
    const harness = new OmniEvmHarness(vm);
    await harness.fund(DEPLOYER, ethers.parseEther("1000"));
    await harness.fund(ALICE, ethers.parseEther("100"));
    await harness.fund(ATTACKER, ethers.parseEther("10"));
    return harness;
  }

  async fund(addrStr, weiAmount) {
    const addr = createAddressFromString(addrStr);
    const acct = (await this.vm.stateManager.getAccount(addr)) ?? new Account();
    acct.balance = BigInt(weiAmount);
    await this.vm.stateManager.putAccount(addr, acct);
  }

  async getBalance(addrStr) {
    const addr = createAddressFromString(addrStr);
    const acct = await this.vm.stateManager.getAccount(addr);
    return acct ? acct.balance : 0n;
  }

  async deploy(artifact, args = [], value = 0n, caller = DEPLOYER) {
    const encodedArgs = args.length > 0 ? artifact.iface.encodeDeploy(args).slice(2) : "";
    const initCode = hexToBytes("0x" + artifact.bin + encodedArgs);
    const res = await this.vm.evm.runCall({
      caller: createAddressFromString(caller),
      data: initCode,
      value: BigInt(value),
      gasLimit: 15_000_000n,
      block: {
        header: {
          timestamp: this.timestamp,
          number: this.blockNumber,
          chainId: REACTIVE_LASNA_CHAIN_ID,
        },
      },
    });
    if (res.execResult.exceptionError) {
      throw new Error(`Deploy failed: ${res.execResult.exceptionError.error}`);
    }
    return {
      address: res.createdAddress.toString(),
      runtimeCode: res.execResult.returnValue,
      iface: artifact.iface,
    };
  }

  async etch(targetAddrStr, runtimeCodeBytes) {
    const targetAddr = createAddressFromString(targetAddrStr);
    await this.vm.stateManager.putCode(targetAddr, runtimeCodeBytes);
  }

  async call(contract, fnName, args = [], { caller = DEPLOYER, value = 0n, expectRevert = false } = {}) {
    const calldata = hexToBytes(contract.iface.encodeFunctionData(fnName, args));
    const res = await this.vm.evm.runCall({
      caller: createAddressFromString(caller),
      to: createAddressFromString(contract.address),
      data: calldata,
      value: BigInt(value),
      gasLimit: 10_000_000n,
      block: {
        header: {
          timestamp: this.timestamp,
          number: this.blockNumber,
          chainId: BASE_SEPOLIA_CHAIN_ID,
        },
      },
    });

    if (expectRevert) {
      assert.ok(res.execResult.exceptionError, `Expected ${fnName} to revert, but it succeeded`);
      return res.execResult;
    }

    if (res.execResult.exceptionError) {
      const revHex = bytesToHex(res.execResult.returnValue);
      throw new Error(`Call ${fnName} reverted (${res.execResult.exceptionError.error}): ${revHex}`);
    }

    const retHex = bytesToHex(res.execResult.returnValue);
    const decoded = retHex && retHex !== "0x" ? contract.iface.decodeFunctionResult(fnName, retHex) : null;
    return { decoded, logs: res.execResult.logs || [] };
  }
}

async function setupFullTopology() {
  const harness = await OmniEvmHarness.create();

  const sysArt = loadArtifact("contracts_mocks_MockOmniSystemContract_sol_MockOmniSystemContract");
  const proxyArt = loadArtifact("contracts_mocks_MockCallbackProxy_sol_MockCallbackProxy");
  const poolArt = loadArtifact("contracts_mocks_MockDEXPool_sol_MockDEXPool");
  const lendingArt = loadArtifact("contracts_mocks_MockLendingMarket_sol_MockLendingMarket");
  const aiArt = loadArtifact("contracts_AIThreatSignalEmitter_sol_AIThreatSignalEmitter");
  const vaultArt = loadArtifact("contracts_AegisVaultCallbackReceiver_sol_AegisVaultCallbackReceiver");
  const guardArt = loadArtifact("contracts_OmniAegisReactiveGuard_sol_OmniAegisReactiveGuard");

  // 1. Deploy and etch MockOmniSystemContract at canonical 0x8888...8888
  const sysTmp = await harness.deploy(sysArt);
  await harness.etch(OMNI_SYSTEM_ADDR, sysTmp.runtimeCode);
  const systemContract = { address: OMNI_SYSTEM_ADDR, iface: sysArt.iface };

  // 2. Deploy and etch MockCallbackProxy at Base Sepolia & Unichain Sepolia canonical addresses
  const proxyTmp = await harness.deploy(proxyArt);
  await harness.etch(BASE_CALLBACK_PROXY, proxyTmp.runtimeCode);
  await harness.etch(UNICHAIN_CALLBACK_PROXY, proxyTmp.runtimeCode);
  const baseProxy = { address: BASE_CALLBACK_PROXY, iface: proxyArt.iface };
  const unichainProxy = { address: UNICHAIN_CALLBACK_PROXY, iface: proxyArt.iface };

  // 3. Deploy Origin Contracts & AI Signal Emitter
  const basePool = await harness.deploy(poolArt, [ethers.parseEther("100"), ethers.parseEther("250000")]);
  const unichainPool = await harness.deploy(poolArt, [ethers.parseEther("100"), ethers.parseEther("250000")]);
  const lendingMarket = await harness.deploy(lendingArt);
  const aiEmitter = await harness.deploy(aiArt, [DEPLOYER]);

  // 4. Deploy Destination Vaults
  const baseVault = await harness.deploy(
    vaultArt,
    [BASE_CALLBACK_PROXY, ethers.ZeroAddress, ethers.parseEther("100"), ethers.parseEther("250000"), 60n],
    ethers.parseEther("1")
  );
  const unichainVault = await harness.deploy(
    vaultArt,
    [UNICHAIN_CALLBACK_PROXY, ethers.ZeroAddress, ethers.parseEther("100"), ethers.parseEther("250000"), 60n],
    ethers.parseEther("1")
  );

  // 5. Deploy OmniAegisReactiveGuard on Reactive Omni (automatically subscribes on 0x8888...8888)
  const reactiveGuard = await harness.deploy(
    guardArt,
    [
      basePool.address,
      unichainPool.address,
      lendingMarket.address,
      aiEmitter.address,
      baseVault.address,
      unichainVault.address,
      true,
    ],
    ethers.parseEther("1")
  );

  await harness.call(baseVault, "setAuthorizedReactiveSender", [reactiveGuard.address, true]);
  await harness.call(unichainVault, "setAuthorizedReactiveSender", [reactiveGuard.address, true]);

  return {
    harness,
    systemContract,
    baseProxy,
    unichainProxy,
    basePool,
    unichainPool,
    lendingMarket,
    aiEmitter,
    baseVault,
    unichainVault,
    reactiveGuard,
  };
}

test("1. Constructor registers all 6 event & Cron100 subscriptions on Reactive Omni SYSTEM (0x8888...8888)", async () => {
  const { harness, systemContract, reactiveGuard } = await setupFullTopology();
  const { decoded } = await harness.call(systemContract, "getActiveSubscriptionsCount", [reactiveGuard.address]);
  assert.equal(decoded[0], 6n);
});

test("2. Rejects unauthorized direct calls to react(LogRecord) from non-SYSTEM callers", async () => {
  const { harness, reactiveGuard, basePool } = await setupFullTopology();
  const syncTopic0 = (await harness.call(reactiveGuard, "DEX_SYNC_TOPIC_0")).decoded[0];
  const fakeLog = {
    chainId: BASE_SEPOLIA_CHAIN_ID,
    contractAddress: basePool.address,
    topic0: syncTopic0,
    topic1: 0n,
    topic2: 0n,
    topic3: 0n,
    data: ethers.AbiCoder.defaultAbiCoder().encode(["uint112", "uint112"], [ethers.parseEther("100"), ethers.parseEther("200000")]),
    blockNumber: 1001n,
    opCode: 1n,
    blockHash: 111n,
    txHash: 222n,
    logIndex: 0n,
  };

  await harness.call(reactiveGuard, "react", [fakeLog], { caller: ATTACKER, expectRevert: true });
});

test("3. Track 1 (Every Second Counts): DEX Flash Crash triggers sub-second Emergency Stop-Loss Callback", async () => {
  const { harness, systemContract, baseProxy, basePool, baseVault, reactiveGuard } = await setupFullTopology();
  const syncTopic0 = (await harness.call(reactiveGuard, "DEX_SYNC_TOPIC_0")).decoded[0];
  const coder = ethers.AbiCoder.defaultAbiCoder();

  // Step 1: Healthy Sync at 2,500 USDC/WETH establishes high-water mark
  await harness.call(systemContract, "deliverLog", [
    reactiveGuard.address,
    {
      chainId: BASE_SEPOLIA_CHAIN_ID,
      contractAddress: basePool.address,
      topic0: syncTopic0,
      topic1: 0n,
      topic2: 0n,
      topic3: 0n,
      data: coder.encode(["uint112", "uint112"], [ethers.parseEther("100"), ethers.parseEther("250000")]),
      blockNumber: 1001n,
      opCode: 1n,
      blockHash: 0xaa01n,
      txHash: 0xbb01n,
      logIndex: 0n,
    },
  ]);

  let qLen = (await harness.call(systemContract, "getCallbackQueueLength")).decoded[0];
  assert.equal(qLen, 0n);

  // Step 2: Flash Crash to 2,200 USDC/WETH (12% drawdown >= 5% threshold)
  await harness.call(systemContract, "deliverLog", [
    reactiveGuard.address,
    {
      chainId: BASE_SEPOLIA_CHAIN_ID,
      contractAddress: basePool.address,
      topic0: syncTopic0,
      topic1: 0n,
      topic2: 0n,
      topic3: 0n,
      data: coder.encode(["uint112", "uint112"], [ethers.parseEther("100"), ethers.parseEther("220000")]),
      blockNumber: 1002n,
      opCode: 1n,
      blockHash: 0xaa02n,
      txHash: 0xbb02n,
      logIndex: 1n,
    },
  ]);

  qLen = (await harness.call(systemContract, "getCallbackQueueLength")).decoded[0];
  assert.equal(qLen, 1n);

  const cb = (await harness.call(systemContract, "getQueuedCallback", [0n])).decoded[0];
  assert.equal(cb.chainId, BASE_SEPOLIA_CHAIN_ID);
  assert.equal(cb.recipient.toLowerCase(), baseVault.address.toLowerCase());

  // Step 3: Relay through Base Sepolia Callback Proxy (injects reactiveGuard.address into payload[4..36])
  await harness.call(baseProxy, "dispatch", [reactiveGuard.address, cb.recipient, cb.gasLimit, cb.payload]);

  const breakerActive = (await harness.call(baseVault, "emergencyCircuitBreakerActive")).decoded[0];
  const riskBal = (await harness.call(baseVault, "riskAssetBalance")).decoded[0];
  const stableBal = (await harness.call(baseVault, "stableReserveBalance")).decoded[0];

  assert.equal(breakerActive, true);
  assert.equal(riskBal, ethers.parseEther("50"));
  assert.equal(stableBal, ethers.parseEther("360000"));
});

test("4. Track 1 (Every Second Counts): Cross-Chain Base Sepolia <-> Unichain Sepolia Arbitrage Callback", async () => {
  const { harness, systemContract, baseProxy, basePool, unichainPool, baseVault, reactiveGuard } =
    await setupFullTopology();
  const syncTopic0 = (await harness.call(reactiveGuard, "DEX_SYNC_TOPIC_0")).decoded[0];
  const coder = ethers.AbiCoder.defaultAbiCoder();

  // Base Sepolia at 2,500 USDC/WETH
  await harness.call(systemContract, "deliverLog", [
    reactiveGuard.address,
    {
      chainId: BASE_SEPOLIA_CHAIN_ID,
      contractAddress: basePool.address,
      topic0: syncTopic0,
      topic1: 0n,
      topic2: 0n,
      topic3: 0n,
      data: coder.encode(["uint112", "uint112"], [ethers.parseEther("100"), ethers.parseEther("250000")]),
      blockNumber: 1010n,
      opCode: 1n,
      blockHash: 0xcc01n,
      txHash: 0xdd01n,
      logIndex: 0n,
    },
  ]);

  // Unichain Sepolia at 2,560 USDC/WETH (240 bps spread >= 150 bps threshold)
  await harness.call(systemContract, "deliverLog", [
    reactiveGuard.address,
    {
      chainId: UNICHAIN_SEPOLIA_CHAIN_ID,
      contractAddress: unichainPool.address,
      topic0: syncTopic0,
      topic1: 0n,
      topic2: 0n,
      topic3: 0n,
      data: coder.encode(["uint112", "uint112"], [ethers.parseEther("100"), ethers.parseEther("256000")]),
      blockNumber: 505n,
      opCode: 1n,
      blockHash: 0xcc02n,
      txHash: 0xdd02n,
      logIndex: 0n,
    },
  ]);

  const qLen = (await harness.call(systemContract, "getCallbackQueueLength")).decoded[0];
  assert.equal(qLen, 1n);

  const cb = (await harness.call(systemContract, "getQueuedCallback", [0n])).decoded[0];
  const beforeStable = (await harness.call(baseVault, "stableReserveBalance")).decoded[0];
  await harness.call(baseProxy, "dispatch", [reactiveGuard.address, cb.recipient, cb.gasLimit, cb.payload]);
  const afterStable = (await harness.call(baseVault, "stableReserveBalance")).decoded[0];

  assert.ok(afterStable > beforeStable, "Arbitrage callback must increase vault stable reserve");
});

test("5. Track 1 (Every Second Counts): Lending Health Factor drop triggers instant Collateral Top-Up", async () => {
  const { harness, systemContract, baseProxy, lendingMarket, baseVault, reactiveGuard } = await setupFullTopology();
  const hfTopic0 = (await harness.call(reactiveGuard, "HEALTH_FACTOR_TOPIC_0")).decoded[0];
  const coder = ethers.AbiCoder.defaultAbiCoder();

  const { decoded: posDecoded } = await harness.call(baseVault, "registerLendingPosition", [
    ALICE,
    ethers.parseEther("10"),
    ethers.parseEther("18000"),
    ethers.parseEther("1.35"),
    ethers.parseEther("5"),
  ]);
  const posId = posDecoded[0];

  await harness.call(systemContract, "deliverLog", [
    reactiveGuard.address,
    {
      chainId: BASE_SEPOLIA_CHAIN_ID,
      contractAddress: lendingMarket.address,
      topic0: hfTopic0,
      topic1: BigInt(ALICE),
      topic2: posId,
      topic3: 0n,
      data: coder.encode(
        ["uint256", "uint256", "uint256"],
        [ethers.parseEther("1.08"), ethers.parseEther("10"), ethers.parseEther("18000")]
      ),
      blockNumber: 1020n,
      opCode: 3n,
      blockHash: 0xee01n,
      txHash: 0xff01n,
      logIndex: 0n,
    },
  ]);

  const cb = (await harness.call(systemContract, "getQueuedCallback", [0n])).decoded[0];
  await harness.call(baseProxy, "dispatch", [reactiveGuard.address, cb.recipient, cb.gasLimit, cb.payload]);

  const posAfter = (await harness.call(baseVault, "positions", [posId])).decoded;
  assert.equal(posAfter[1], ethers.parseEther("12")); // Collateral topped up by 2 ETH
  assert.equal(posAfter[3], ethers.parseEther("1.43")); // Health factor restored to 1.43 WAD
});

test("6. Track 2 (Set It and Forget It): Cron100 DCA & Base Sepolia 200ms Block Timestamp Safety", async () => {
  const { harness, systemContract, baseProxy, baseVault, reactiveGuard } = await setupFullTopology();
  const schedTopic0 = (await harness.call(reactiveGuard, "SCHEDULE_REGISTERED_TOPIC_0")).decoded[0];
  const cronTopic0 = (await harness.call(reactiveGuard, "CRON100_TOPIC_0")).decoded[0];
  const coder = ethers.AbiCoder.defaultAbiCoder();

  const { decoded: schedDecoded } = await harness.call(
    baseVault,
    "registerAutomationSchedule",
    [0, ethers.parseEther("1000"), 300n, ethers.parseEther("2000"), ethers.parseEther("3000")],
    { caller: ALICE }
  );
  const schedId = schedDecoded[0];

  // Deliver ScheduleRegistered to Reactive Guard
  await harness.call(systemContract, "deliverLog", [
    reactiveGuard.address,
    {
      chainId: BASE_SEPOLIA_CHAIN_ID,
      contractAddress: baseVault.address,
      topic0: schedTopic0,
      topic1: schedId,
      topic2: BigInt(ALICE),
      topic3: 0n,
      data: coder.encode(["uint256", "uint8", "uint256", "uint256"], [BASE_SEPOLIA_CHAIN_ID, 0, ethers.parseEther("1000"), 300n]),
      blockNumber: 1030n,
      opCode: 3n,
      blockHash: 0x1111n,
      txHash: 0x2222n,
      logIndex: 0n,
    },
  ]);

  // Deliver first Cron100 tick
  await harness.call(systemContract, "deliverLog", [
    reactiveGuard.address,
    {
      chainId: REACTIVE_LASNA_CHAIN_ID,
      contractAddress: LEGACY_CRON_ADDR,
      topic0: cronTopic0,
      topic1: 0n,
      topic2: 0n,
      topic3: 0n,
      data: coder.encode(["uint256"], [1100n]),
      blockNumber: 1100n,
      opCode: 1n,
      blockHash: 0x3333n,
      txHash: 0x4444n,
      logIndex: 0n,
    },
  ]);

  const cb1 = (await harness.call(systemContract, "getQueuedCallback", [0n])).decoded[0];
  await harness.call(baseProxy, "dispatch", [reactiveGuard.address, cb1.recipient, cb1.gasLimit, cb1.payload]);

  // Advance Base Sepolia by 500 blocks (at 200ms/block = only 100s < 300s interval!)
  harness.blockNumber += 500n;
  harness.timestamp += 100n;

  await harness.call(systemContract, "deliverLog", [
    reactiveGuard.address,
    {
      chainId: REACTIVE_LASNA_CHAIN_ID,
      contractAddress: LEGACY_CRON_ADDR,
      topic0: cronTopic0,
      topic1: 0n,
      topic2: 0n,
      topic3: 0n,
      data: coder.encode(["uint256"], [1200n]),
      blockNumber: 1200n,
      opCode: 1n,
      blockHash: 0x3334n,
      txHash: 0x4445n,
      logIndex: 0n,
    },
  ]);

  const cb2 = (await harness.call(systemContract, "getQueuedCallback", [1n])).decoded[0];
  // Must revert because timestamp only advanced 100s (< 300s interval)
  await harness.call(baseProxy, "dispatch", [reactiveGuard.address, cb2.recipient, cb2.gasLimit, cb2.payload], {
    expectRevert: true,
  });

  // Advance timestamp by another 205s (total +305s >= 300s interval) -> succeeds!
  harness.timestamp += 205n;
  await harness.call(baseProxy, "dispatch", [reactiveGuard.address, cb2.recipient, cb2.gasLimit, cb2.payload]);

  const schedState = (await harness.call(baseVault, "schedules", [schedId])).decoded;
  assert.equal(schedState[9], 2n); // executionCount == 2
  assert.equal(schedState[8], ethers.parseEther("2000")); // totalExecutedAmount == 2,000 USDC
});

test("7. Track 3 (Reactive Meets AI): Neural Network threat signal triggers preemptive vault shield", async () => {
  const { harness, systemContract, baseProxy, basePool, aiEmitter, baseVault, reactiveGuard } =
    await setupFullTopology();
  const aiTopic0 = (await harness.call(reactiveGuard, "AI_ORACLE_SIGNAL_TOPIC_0")).decoded[0];
  const coder = ethers.AbiCoder.defaultAbiCoder();
  const modelCommit = ethers.keccak256(ethers.toUtf8Bytes("AegisTCN-ResidualMLP-v1.0-commit"));

  await harness.call(aiEmitter, "publishSignal", [
    BASE_SEPOLIA_CHAIN_ID,
    basePool.address,
    8400n,
    620n,
    -480n,
    2, // EMERGENCY_STOP_LOSS
    modelCommit,
  ]);

  await harness.call(systemContract, "deliverLog", [
    reactiveGuard.address,
    {
      chainId: BASE_SEPOLIA_CHAIN_ID,
      contractAddress: aiEmitter.address,
      topic0: aiTopic0,
      topic1: BASE_SEPOLIA_CHAIN_ID,
      topic2: BigInt(basePool.address),
      topic3: 0n,
      data: coder.encode(
        ["uint256", "uint256", "int256", "uint8", "bytes32", "uint256"],
        [8400n, 620n, -480n, 2, modelCommit, harness.timestamp]
      ),
      blockNumber: 1050n,
      opCode: 3n,
      blockHash: 0x7777n,
      txHash: 0x8888n,
      logIndex: 0n,
    },
  ]);

  const cb = (await harness.call(systemContract, "getQueuedCallback", [0n])).decoded[0];
  await harness.call(baseProxy, "dispatch", [reactiveGuard.address, cb.recipient, cb.gasLimit, cb.payload]);

  const riskAfter = (await harness.call(baseVault, "riskAssetBalance")).decoded[0];
  const receipt = (await harness.call(baseVault, "getReceipt", [0n])).decoded[0];
  assert.equal(riskAfter, ethers.parseEther("60")); // 40% shifted preemptively
  assert.equal(receipt.metadataHash, modelCommit);
});

test("8. Pause, Resume & Debt Settlement on Reactive Omni SYSTEM (0x8888...8888)", async () => {
  const { harness, systemContract, reactiveGuard } = await setupFullTopology();

  await harness.call(reactiveGuard, "pauseSubscriptions");
  let activeSubs = (await harness.call(systemContract, "getActiveSubscriptionsCount", [reactiveGuard.address])).decoded[0];
  assert.equal(activeSubs, 0n);

  await harness.call(systemContract, "setDebt", [reactiveGuard.address, ethers.parseEther("0.25")]);
  const sysBefore = await harness.getBalance(OMNI_SYSTEM_ADDR);

  await harness.call(reactiveGuard, "resumeSubscriptions");
  const sysAfter = await harness.getBalance(OMNI_SYSTEM_ADDR);
  activeSubs = (await harness.call(systemContract, "getActiveSubscriptionsCount", [reactiveGuard.address])).decoded[0];

  assert.equal(sysAfter - sysBefore, ethers.parseEther("0.25"));
  assert.equal(activeSubs, 6n);
});

test("9. Dual Callback Authentication rejects direct calls and spoofed reactive senders", async () => {
  const { harness, baseProxy, baseVault, reactiveGuard } = await setupFullTopology();

  // 1. Direct call bypassing CallbackProxy must revert with NotAuthorized
  await harness.call(
    baseVault,
    "executeEmergencyStopLoss",
    [reactiveGuard.address, 1, ethers.parseEther("2000"), 800n, 0x1234n],
    { caller: ATTACKER, expectRevert: true }
  );

  // 2. Call through legitimate CallbackProxy but with unapproved reactive sender must revert with CallbackNotAuthorized
  const badPayload = baseVault.iface.encodeFunctionData("executeEmergencyStopLoss", [
    ethers.ZeroAddress,
    1,
    ethers.parseEther("2000"),
    800n,
    0x1234n,
  ]);
  await harness.call(
    baseProxy,
    "dispatch",
    [ATTACKER, baseVault.address, 800000n, badPayload],
    { expectRevert: true }
  );
});

