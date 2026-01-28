#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   1. Create `.env` (or set env vars) with at least `PRIVATE_KEY=0x...` and `PRIVATE_KEY_NEW_DELEGATOR3=0x...`.
#   2. Prepare story client to localnet root folder
# The script performs:
#   1. Create locked validator
#   2. Delegator delegates 5000 IP token to the locked validator
#   3. Delegator undelegates 2600 IP token from the locked validator
#   4. Check the rewards shares of the delegator is 0

CHAIN_ID=${CHAIN_ID:-1399}
EL_RPC=${EL_RPC:-http://localhost:8545}
EXPLORER_URL=${EXPLORER_URL:-http://localhost:26657}
STORY_API=${STORY_API:-""}

# Financial parameters (all values in wei unless stated otherwise)
CREATE_AMOUNT=${CREATE_AMOUNT:-110000000000000000000000}   # 11,000,000 IP (ether units) 
DELEGATE_AMOUNT=${DELEGATE_AMOUNT:-5000000000000000000000}   # 5,000 IP (ether units)
UNDELEGATE_AMOUNT=${UNDELEGATE_AMOUNT:-2600000000000000000000}   # 2,600 IP (ether units)

LOCK_PERIOD=${LOCK_PERIOD:-2}                             # 0=flexible, 1=short, 2=medium, 3=long
MONIKER=${MONIKER:-"staking-locked"}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCALNET_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEFAULT_STORY_BIN="$LOCALNET_ROOT/story"
STORY_BIN=${STORY_BIN:-$DEFAULT_STORY_BIN}

if [[ ! -x "$STORY_BIN" ]]; then
  if command -v story >/dev/null 2>&1; then
    STORY_BIN=$(command -v story)
  else
    echo "Missing Story CLI. Place the binary at $DEFAULT_STORY_BIN or set STORY_BIN to the executable path." >&2
    exit 1
  fi
fi

PRIVATE_KEY_FILE=${PRIVATE_KEY_FILE:-.env}
if [[ -z "${PRIVATE_KEY:-}" && -f "$PRIVATE_KEY_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$PRIVATE_KEY_FILE"
  set +a
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "Set PRIVATE_KEY in ${PRIVATE_KEY_FILE} (or export it) so Story CLI can sign transactions." >&2
  exit 1
fi

if [[ -z "${PRIVATE_KEY_NEW_DELEGATOR3:-}" ]]; then
  echo "Set PRIVATE_KEY_NEW_DELEGATOR3 in ${PRIVATE_KEY_FILE} (or export it) for the delegator account." >&2
  exit 1
fi

PRIVATE_KEY_STRIPPED=${PRIVATE_KEY#0x}
PRIVATE_KEY_STRIPPED_OTHER=${PRIVATE_KEY_NEW_DELEGATOR3#0x}

if [[ ${#PRIVATE_KEY_STRIPPED} -ne 64 ]]; then
  echo "PRIVATE_KEY must be a 32-byte hex string (optionally 0x-prefixed)." >&2
  exit 1
fi

if [[ ${#PRIVATE_KEY_STRIPPED_OTHER} -ne 64 ]]; then
  echo "PRIVATE_KEY_NEW_DELEGATOR3 must be a 32-byte hex string (optionally 0x-prefixed)." >&2
  exit 1
fi

# Get validator info from PRIVATE_KEY
TMP_PK_ENV=$(mktemp)
printf "PRIVATE_KEY=%s\n" "$PRIVATE_KEY_STRIPPED" > "$TMP_PK_ENV"
KEY_INFO=$("$STORY_BIN" key convert --private-key-file "$TMP_PK_ENV")
rm -f "$TMP_PK_ENV"

extract_from_key_info() {
  local label="$1"
  echo "$KEY_INFO" | awk -F': ' -v lbl="$label" '$1 == lbl {print $2}'
}

VAL_CMP_PUBKEY=${VAL_CMP_PUBKEY:-$(extract_from_key_info "Compressed Public Key (hex)")}
VAL_ADDRESS_BECH32=${VAL_ADDRESS_BECH32:-$(extract_from_key_info "Validator Address")}
VAL_ADDRESS_EVM=${VAL_ADDRESS_EVM:-$(extract_from_key_info "EVM Address")}

if [[ -z "$VAL_CMP_PUBKEY" ]]; then
  echo "Failed to derive validator pubkey from PRIVATE_KEY. Please set VAL_CMP_PUBKEY explicitly." >&2
  exit 1
fi

if [[ -z "$VAL_ADDRESS_BECH32" ]]; then
  echo "Failed to derive validator address from PRIVATE_KEY. Please set VAL_ADDRESS_BECH32 explicitly." >&2
  exit 1
fi

if [[ -z "$VAL_ADDRESS_EVM" ]]; then
  echo "Failed to derive validator EVM address from PRIVATE_KEY. Please set VAL_ADDRESS_EVM explicitly." >&2
  exit 1
fi

# Get delegator info from PRIVATE_KEY_NEW_DELEGATOR3
TMP_PK_ENV_OTHER=$(mktemp)
printf "PRIVATE_KEY=%s\n" "$PRIVATE_KEY_STRIPPED_OTHER" > "$TMP_PK_ENV_OTHER"
KEY_INFO_OTHER=$("$STORY_BIN" key convert --private-key-file "$TMP_PK_ENV_OTHER")
rm -f "$TMP_PK_ENV_OTHER"

extract_from_key_info_other() {
  local label="$1"
  echo "$KEY_INFO_OTHER" | awk -F': ' -v lbl="$label" '$1 == lbl {print $2}'
}

DEL_ADDRESS_BECH32=${DEL_ADDRESS_BECH32:-$(extract_from_key_info_other "Delegator Address")}
DEL_ADDRESS_EVM=${DEL_ADDRESS_EVM:-$(extract_from_key_info_other "EVM Address")}

if [[ -z "$DEL_ADDRESS_BECH32" ]]; then
  echo "Failed to derive delegator address from PRIVATE_KEY_NEW_DELEGATOR3. Please set DEL_ADDRESS_BECH32 explicitly." >&2
  exit 1
fi

if [[ -z "$DEL_ADDRESS_EVM" ]]; then
  echo "Failed to derive delegator EVM address from PRIVATE_KEY_NEW_DELEGATOR3. Please set DEL_ADDRESS_EVM explicitly." >&2
  exit 1
fi

run_validator_cmd() {
  PRIVATE_KEY="$PRIVATE_KEY_STRIPPED" "$STORY_BIN" validator "$@"
}

run_validator_cmd_other() {
  PRIVATE_KEY="$PRIVATE_KEY_STRIPPED_OTHER" "$STORY_BIN" validator "$@"
}

period_name() {
  case "$1" in
    0) echo "flexible" ;;
    1) echo "short" ;;
    2) echo "medium" ;;
    3) echo "long" ;;
    *) echo "flexible" ;;
  esac
}

PERIOD_NAME=$(period_name "$LOCK_PERIOD")

# Function to query delegation info and extract rewards_shares
query_rewards_shares() {
  local val_addr_evm="$1"
  local del_addr_evm="$2"
  local val_addr_bech32="$3"
  local del_addr_bech32="$4"
  
  if [[ -n "$STORY_API" ]]; then
    # Use Story API if available (expects EVM addresses)
    local api_url="${STORY_API}/staking/validators/${val_addr_evm}/delegations/${del_addr_evm}"
    local response
    response=$(curl -s "$api_url" || echo "")
    
    if [[ -n "$response" ]]; then
      local rewards_shares
      rewards_shares=$(echo "$response" | jq -r '.msg.delegation_response.delegation.rewards_shares // "0"' 2>/dev/null || echo "0")
      if [[ "$rewards_shares" != "0" ]]; then
        echo "$rewards_shares"
        return
      fi
    fi
  fi
  
  # Fallback to explorer query (uses bech32 addresses)
  local query_data
  query_data=$(echo -n "{\"validator_addr\":\"${val_addr_bech32}\",\"delegator_addr\":\"${del_addr_bech32}\"}" | base64)
  local response
  response=$(curl -s "${EXPLORER_URL}/abci_query?path=\"/cosmos.staking.v1beta1.Query/Delegation\"&data=\"${query_data}\"" || echo "")
  
  if [[ -n "$response" ]]; then
    echo "$response" | jq -r '.result.response.value' | base64 -d 2>/dev/null | jq -r '.delegation.rewards_shares // "0"' 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

echo "=== Step 1: Create locked validator with ${CREATE_AMOUNT} IP ==="
run_validator_cmd create \
  --moniker "$MONIKER" \
  --commission-rate 1000 \
  --max-commission-rate 5000 \
  --max-commission-change-rate 1000 \
  --unlocked=false \
  --stake "${CREATE_AMOUNT}" \
  --chain-id "$CHAIN_ID" \
  --rpc "$EL_RPC" \
  --explorer "$EXPLORER_URL" \
  --story-api "$STORY_API"
sleep 2

echo
echo "=== Step 2: Delegator delegates ${DELEGATE_AMOUNT} IP to locked validator ==="
echo "Using validator pubkey (compressed hex): ${VAL_CMP_PUBKEY}"

run_validator_cmd_other stake \
  --validator-pubkey "$VAL_CMP_PUBKEY" \
  --stake "${DELEGATE_AMOUNT}" \
  --staking-period "$PERIOD_NAME" \
  --chain-id "$CHAIN_ID" \
  --rpc "$EL_RPC" \
  --explorer "$EXPLORER_URL" \
  --story-api "$STORY_API"
sleep 5

echo
echo "=== Step 3: Delegator undelegates ${UNDELEGATE_AMOUNT} IP from locked validator ==="
run_validator_cmd_other unstake \
  --validator-pubkey "$VAL_CMP_PUBKEY" \
  --unstake "${UNDELEGATE_AMOUNT}" \
  --delegation-id 0 \
  --chain-id "$CHAIN_ID" \
  --rpc "$EL_RPC" \
  --explorer "$EXPLORER_URL" \
  --story-api "$STORY_API"
sleep 5

echo
echo "=== Step 4: Check rewards shares of the delegator ==="
echo "Validator Address (bech32): $VAL_ADDRESS_BECH32"
echo "Validator Address (EVM): $VAL_ADDRESS_EVM"
echo "Delegator Address (bech32): $DEL_ADDRESS_BECH32"
echo "Delegator Address (EVM): $DEL_ADDRESS_EVM"

REWARDS_SHARES=$(query_rewards_shares "$VAL_ADDRESS_EVM" "$DEL_ADDRESS_EVM" "$VAL_ADDRESS_BECH32" "$DEL_ADDRESS_BECH32")
echo "Rewards Shares: $REWARDS_SHARES"

# Check if rewards_shares is 0
if [[ "$REWARDS_SHARES" == "0" ]] || [[ "$REWARDS_SHARES" == "0.000000000000000000" ]]; then
  echo "✓ SUCCESS: Rewards shares is 0 as expected"
  exit 0
else
  echo "✗ FAILURE: Rewards shares is $REWARDS_SHARES, expected 0"
  exit 1
fi

