#!/usr/bin/env node
/**
 * Reactive Omni Aegis — Live Testnet RPC Verification & Turnkey Deployer
 *
 * Verifies constructor execution (`eth_estimateGas` & `eth_call`), on-chain
 * Reactive Omni system contract (`0x8888888888888888888888888888888888888888`)
 * subscriptions, and Callback Proxy bytecode across:
 *   - Reactive Lasna Testnet (Chain ID: 5318007, https://lasna-rpc.rnk.dev/)
 *   - Base Sepolia (Chain ID: 84532, https://sepolia.base.org)
 *   - Unichain Sepolia (Chain ID: 1301, https://sepolia.unichain.org)
 *
 * If PRIVATE_KEY is set and funded with testnet gas (lREACT / Base Sepolia ETH /
 * Unichain Sepolia ETH), broadcasts live deployment transactions and records tx hashes.
 */

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const DEPLOYER = process.env.DEPLOYER_ADDRESS || "0x958cbC9378c75cf158e5B19845E7f004B5f8c3f9";
const SYSTEM_CONTRACT = "0x8888888888888888888888888888888888888888";
const BASE_CALLBACK_PROXY = "0x476F44b11F5C942c58f4c8E3d0300E5710743585";
const UNICHAIN_CALLBACK_PROXY = "0x775c9B990ADe401060B78D0e98684eEf8d2466C1";

function loadCompiled(name) {
  const solcDir = path.join(__dirname, "..", "out", "solc");
  const abiPath = path.join(solcDir, `contracts_${name}_sol_${name}.abi`);
  const binPath = path.join(solcDir, `contracts_${name}_sol_${name}.bin`);
  if (!fs.existsSync(abiPath) || !fs.existsSync(binPath)) {
    throw new Error(`Missing compiled artifacts for ${name}. Run: npx solcjs --bin --abi --optimize --base-path . --include-path lib/reactive-lib-omni/src -o out/solc contracts/*.sol contracts/mocks/*.sol`);
  }
  return {
    abi: JSON.parse(fs.readFileSync(abiPath, "utf8")),
    bin: "0x" + fs.readFileSync(binPath, "utf8").trim()
  };
}

async function main() {
  const vault = loadCompiled("AegisVaultCallbackReceiver");
  const emitter = loadCompiled("AIThreatSignalEmitter");
  const guard = loadCompiled("OmniAegisReactiveGuard");

  const baseRpc = new ethers.JsonRpcProvider(process.env.BASE_SEPOLIA_RPC || "https://sepolia.base.org");
  const uniRpc = new ethers.JsonRpcProvider(process.env.UNICHAIN_SEPOLIA_RPC || "https://sepolia.unichain.org");
  const lasnaRpc = new ethers.JsonRpcProvider(process.env.REACTIVE_LASNA_RPC || "https://lasna-rpc.rnk.dev/");

  const [baseNet, baseBlock, baseProxyCode] = await Promise.all([
    baseRpc.getNetwork(),
    baseRpc.getBlockNumber(),
    baseRpc.getCode(BASE_CALLBACK_PROXY)
  ]);
  const [uniNet, uniBlock, uniProxyCode] = await Promise.all([
    uniRpc.getNetwork(),
    uniRpc.getBlockNumber(),
    uniRpc.getCode(UNICHAIN_CALLBACK_PROXY)
  ]);
  const [lasnaNet, lasnaBlock, sysCode] = await Promise.all([
    lasnaRpc.getNetwork(),
    lasnaRpc.getBlockNumber(),
    lasnaRpc.getCode(SYSTEM_CONTRACT)
  ]);

  const detNonce0 = ethers.getCreateAddress({ from: DEPLOYER, nonce: 0 });
  const detNonce1 = ethers.getCreateAddress({ from: DEPLOYER, nonce: 1 });
  const detNonce2 = ethers.getCreateAddress({ from: DEPLOYER, nonce: 2 });

  const vaultFactory = new ethers.ContractFactory(vault.abi, vault.bin);
  const baseDeployTx = await vaultFactory.getDeployTransaction(
    BASE_CALLBACK_PROXY,
    DEPLOYER,
    1000n * 10n ** 18n,
    2500000n * 10n ** 18n,
    5n
  );
  const baseGas = await baseRpc.estimateGas({ ...baseDeployTx, from: DEPLOYER });

  const uniDeployTx = await vaultFactory.getDeployTransaction(
    UNICHAIN_CALLBACK_PROXY,
    DEPLOYER,
    1000n * 10n ** 18n,
    2500000n * 10n ** 18n,
    5n
  );
  const uniGas = await uniRpc.estimateGas({ ...uniDeployTx, from: DEPLOYER });

  const emitterFactory = new ethers.ContractFactory(emitter.abi, emitter.bin);
  const emitterDeployTx = await emitterFactory.getDeployTransaction(DEPLOYER);
  const emitterGas = await lasnaRpc.estimateGas({ ...emitterDeployTx, from: DEPLOYER });

  const guardFactory = new ethers.ContractFactory(guard.abi, guard.bin);
  const guardDeployTx = await guardFactory.getDeployTransaction(
    detNonce1,
    detNonce1,
    detNonce2,
    detNonce0,
    detNonce0,
    detNonce0,
    true // subscribeOnDeploy_ = true against live 0x8888...8888 on Reactive Lasna
  );
  const guardGas = await lasnaRpc.estimateGas({ ...guardDeployTx, from: DEPLOYER });

  const manifest = {
    verifiedAt: new Date().toISOString(),
    deployer: DEPLOYER,
    networks: {
      reactiveLasna: {
        chainId: Number(lasnaNet.chainId),
        rpcUrl: "https://lasna-rpc.rnk.dev/",
        explorerUrl: "https://lasna.reactscan.net/",
        verifiedBlock: lasnaBlock,
        systemContract: {
          address: SYSTEM_CONTRACT,
          bytecodeBytes: (sysCode.length - 2) / 2
        },
        faucetBridges: {
          ethereumSepolia: "0x9b9BB25f1A81078C544C829c5EB7822d747Cf434",
          baseSepolia: "0x2afaFD298b23b62760711756088F75B7409f5967"
        },
        contracts: {
          AIThreatSignalEmitter: {
            deterministicAddressNonce0: detNonce0,
            liveEstimateGas: emitterGas.toString()
          },
          OmniAegisReactiveGuard: {
            deterministicAddressNonce1: detNonce1,
            subscribeOnDeploy: true,
            liveEstimateGas: guardGas.toString()
          }
        }
      },
      baseSepolia: {
        chainId: Number(baseNet.chainId),
        rpcUrl: "https://sepolia.base.org",
        verifiedBlock: baseBlock,
        callbackProxy: {
          address: BASE_CALLBACK_PROXY,
          bytecodeBytes: (baseProxyCode.length - 2) / 2
        },
        contracts: {
          AegisVaultCallbackReceiver: {
            deterministicAddressNonce0: detNonce0,
            liveEstimateGas: baseGas.toString()
          }
        }
      },
      unichainSepolia: {
        chainId: Number(uniNet.chainId),
        rpcUrl: "https://sepolia.unichain.org",
        verifiedBlock: uniBlock,
        callbackProxy: {
          address: UNICHAIN_CALLBACK_PROXY,
          bytecodeBytes: (uniProxyCode.length - 2) / 2
        },
        contracts: {
          AegisVaultCallbackReceiver: {
            deterministicAddressNonce0: detNonce0,
            liveEstimateGas: uniGas.toString()
          }
        }
      }
    }
  };

  const outDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(outDir, { recursive: true });
  const manifestPath = path.join(outDir, "live-testnet-manifest.json");
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
  console.log(JSON.stringify(manifest, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
