#!/usr/bin/env bash
set -euo pipefail

# Helper script to check validator status and delegations
# Useful for determining how much to unstake

CHAIN_ID=${CHAIN_ID:-1399}
EXPLORER_URL=${EXPLORER_URL:-http://localhost:26657}

# Function to query validator info
query_validator() {
  local val_addr="$1"
  echo "Querying validator: $val_addr"
  curl -s "$EXPLORER_URL/abci_query?path=\"/cosmos.staking.v1beta1.Query/Validator\"&data=\"$(echo -n "{\"validator_addr\":\"$val_addr\"}" | base64)\"" | \
    jq -r '.result.response.value' | base64 -d 2>/dev/null | jq '.' || echo "Failed to query validator"
}

# Function to query delegations
query_delegations() {
  local del_addr="$1"
  echo "Querying delegations for: $del_addr"
  curl -s "$EXPLORER_URL/abci_query?path=\"/cosmos.staking.v1beta1.Query/DelegatorDelegations\"&data=\"$(echo -n "{\"delegator_addr\":\"$del_addr\"}" | base64)\"" | \
    jq -r '.result.response.value' | base64 -d 2>/dev/null | jq '.' || echo "Failed to query delegations"
}

# Function to get current height
get_height() {
  curl -s "$EXPLORER_URL/status" | jq -r '.result.sync_info.latest_block_height' 2>/dev/null || echo "Unknown"
}

echo "=========================================="
echo "Validator Status Checker"
echo "=========================================="
echo ""

HEIGHT=$(get_height)
echo "Current block height: $HEIGHT"
echo ""

if [[ $# -ge 1 ]]; then
  VALIDATOR_ADDR="$1"
  query_validator "$VALIDATOR_ADDR"
  
  if [[ $# -ge 2 ]]; then
    DELEGATOR_ADDR="$2"
    echo ""
    query_delegations "$DELEGATOR_ADDR"
  fi
else
  echo "Usage: $0 <validator_address> [delegator_address]"
  echo ""
  echo "Example:"
  echo "  $0 storyvaloper1qz5y9k7n6yghddyx3ht48f2jhzge6knr445x5n story1qz5y9k7n6yghddyx3ht48f2jhzge6knrm6q8lc"
  echo ""
  echo "To get validator info from a running container:"
  echo "  docker exec validator1-node story validator export"
fi

