#!/usr/bin/env bash
# Deploy and set up everything on a running Anvil node, in two forge runs (see DeployLocalVrf).
# Usage: script/deploy-local.sh   (PRIVATE_KEY and RPC_URL default to Anvil account 0 and localhost)
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
export PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
SCRIPT=script/DeployAndSetupLocal.s.sol

# The mock's createSubscription reads blockhash(block.number - 1), which underflows at block 0
if [ "$(cast block-number --rpc-url "$RPC_URL")" = "0" ]; then
  cast rpc anvil_mine --rpc-url "$RPC_URL" > /dev/null
fi

VRF_COORDINATOR=$(forge script "$SCRIPT:DeployLocalVrf" --rpc-url "$RPC_URL" --broadcast \
  | awk '/VRF_COORDINATOR:/ { print $2 }')
export VRF_COORDINATOR

forge script "$SCRIPT:DeployAndSetupLocal" --rpc-url "$RPC_URL" --broadcast \
  | sed -n '/=== DEPLOYMENT COMPLETE/,/VRF:/p'
