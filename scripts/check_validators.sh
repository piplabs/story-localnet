#!/bin/bash

# Script to check all validators using CometBFT validators API

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCALNET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration - use validator1 RPC (main chain, port 26657)
# Use validator1-node RPC to check validators on main chain
RPC_URL=${RPC_URL:-http://localhost:26657}
PER_PAGE=${PER_PAGE:-200}

echo "=========================================="
echo "Checking Validators"
echo "=========================================="
echo ""
echo "Using RPC: $RPC_URL"
echo ""

# Get current height
HEIGHT=$(curl -s "$RPC_URL/status" | jq -r '.result.sync_info.latest_block_height' 2>/dev/null || echo "unknown")
echo "Current block height: $HEIGHT"
echo ""

# Get validators
echo "Fetching validators..."
VALIDATORS_RESPONSE=$(curl -s "${RPC_URL}/validators?per_page=${PER_PAGE}")

if [[ -z "$VALIDATORS_RESPONSE" ]]; then
  echo "Error: Failed to fetch validators" >&2
  exit 1
fi

# Parse validators
VALIDATORS=$(echo "$VALIDATORS_RESPONSE" | jq -r '.result.validators[]' 2>/dev/null)

if [[ -z "$VALIDATORS" ]]; then
  echo "No validators found"
  exit 0
fi

# Count validators
VALIDATOR_COUNT=$(echo "$VALIDATORS_RESPONSE" | jq -r '.result.validators | length' 2>/dev/null || echo "0")
echo "Total validators: $VALIDATOR_COUNT"
echo ""

# Display validators
echo "=========================================="
echo "Validators List:"
echo "=========================================="
echo ""

echo "$VALIDATORS_RESPONSE" | jq -r '.result.validators[] | "Address: \(.address)\nPubkey: \(.pub_key.value)\nVoting Power: \(.voting_power)\nProposer Priority: \(.proposer_priority)\n---"' 2>/dev/null || {
  echo "$VALIDATORS_RESPONSE" | jq '.' 2>/dev/null || echo "$VALIDATORS_RESPONSE"
}

echo ""
echo "=========================================="
echo "Summary:"
echo "=========================================="
echo "Total validators: $VALIDATOR_COUNT"
echo ""

# Check for validators with zero voting power
ZERO_POWER_COUNT=$(echo "$VALIDATORS_RESPONSE" | jq -r '[.result.validators[] | select(.voting_power == "0")] | length' 2>/dev/null || echo "0")
if [[ "$ZERO_POWER_COUNT" -gt 0 ]]; then
  echo "⚠️  Validators with zero voting power: $ZERO_POWER_COUNT"
  echo ""
  echo "Zero power validators:"
  echo "$VALIDATORS_RESPONSE" | jq -r '.result.validators[] | select(.voting_power == "0") | "  - Address: \(.address)"' 2>/dev/null
fi

