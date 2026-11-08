#!/usr/bin/env bash
# ==============================================================================
# Reactive Omni Aegis — End-to-End Multi-Chain Deployment & Sourcify Verification
# ==============================================================================
# Target Chains:
#   - Base Sepolia (Chain ID: 84532, Callback Proxy: 0x476F44b11F5C942c58f4c8E3d0300E5710743585)
#   - Unichain Sepolia (Chain ID: 1301, Callback Proxy: 0x775c9B990ADe401060B78D0e98684eEf8d2466C1)
#   - Reactive Lasna Testnet (Chain ID: 5318007, System Contract: 0x8888888888888888888888888888888888888888)
#   - Reactive Mainnet (Chain ID: 1597, System Contract: 0x8888888888888888888888888888888888888888)
# ==============================================================================

set -euo pipefail

BASE_SEPOLIA_RPC="${BASE_SEPOLIA_RPC:-https://sepolia.base.org}"
UNICHAIN_SEPOLIA_RPC="${UNICHAIN_SEPOLIA_RPC:-https://sepolia.unichain.org}"
REACTIVE_RPC_URL="${REACTIVE_RPC_URL:-https://lasna-rpc.rnk.dev/}"
REACTIVE_CHAIN_ID="${REACTIVE_CHAIN_ID:-5318007}"

BASE_CALLBACK_PROXY="0x476F44b11F5C942c58f4c8E3d0300E5710743585"
UNICHAIN_CALLBACK_PROXY="0x775c9B990ADe401060B78D0e98684eEf8d2466C1"

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "Usage: PRIVATE_KEY=0x... REACTIVE_PRIVATE_KEY=0x... ./scripts/deploy-and-verify.sh"
  exit 1
fi

REACTIVE_PRIVATE_KEY="${REACTIVE_PRIVATE_KEY:-$PRIVATE_KEY}"

echo "[1/4] Deploying Origin & Destination contracts on Base Sepolia (84532)..."
forge script script/DeployOmniAegis.s.sol:DeployOmniAegis \
  --sig "runOriginAndDestination(address)" "$BASE_CALLBACK_PROXY" \
  --rpc-url "$BASE_SEPOLIA_RPC" \
  --broadcast

echo "[2/4] Deploying Origin & Destination contracts on Unichain Sepolia (1301)..."
forge script script/DeployOmniAegis.s.sol:DeployOmniAegis \
  --sig "runOriginAndDestination(address)" "$UNICHAIN_CALLBACK_PROXY" \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC" \
  --broadcast

echo "[3/4] Deploying OmniAegisReactiveGuard on Reactive Omni ($REACTIVE_CHAIN_ID) with Sourcify verification..."
forge create \
  --broadcast \
  --rpc-url "$REACTIVE_RPC_URL" \
  --private-key "$REACTIVE_PRIVATE_KEY" \
  --chain-id "$REACTIVE_CHAIN_ID" \
  --value 0.05ether \
  --verify \
  --verifier sourcify \
  contracts/OmniAegisReactiveGuard.sol:OmniAegisReactiveGuard \
  --constructor-args \
    "${BASE_POOL_ADDR}" \
    "${UNICHAIN_POOL_ADDR}" \
    "${BASE_LENDING_ADDR}" \
    "${AI_EMITTER_ADDR}" \
    "${BASE_VAULT_ADDR}" \
    "${UNICHAIN_VAULT_ADDR}" \
    true

echo "[4/4] Deployment & Sourcify verification complete!"
