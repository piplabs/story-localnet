#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   1. Create `.env` (or set env vars) with at least `PRIVATE_KEY_OTHER=0x...`.
#   2. Ensure Docker is running and the validator container is up.
#   3. Optionally set `VALIDATOR_CONTAINER` to pick which genesis validator to use.
#   4. Optional overrides: `VAL_PUBKEY_B64`, `VAL_CMP_PUBKEY`, `VAL_ADDRESS_BECH32`.
#      These must match the container export or the script will exit.
#   5. Prepare story client to localnet root folder.
#
# What this does (using one validator end-to-end):
#   1. Reads validator pubkey/addresses from `story validator export` in Docker.
#   2. Delegator stakes to that validator (compressed hex pubkey).
#   3. Delegator unstakes using the same validator pubkey and the returned delegation ID.
#   4. Queries rewards shares using the same validator addresses.
#   5. Prints all key/address info for verification.

CHAIN_ID=${CHAIN_ID:-1399}
EL_RPC=${EL_RPC:-http://localhost:8545}
EXPLORER_URL=${EXPLORER_URL:-http://localhost:26657}
STORY_API=${STORY_API:-""}

# Financial parameters (all values in wei unless stated otherwise)
DELEGATE_AMOUNT=${DELEGATE_AMOUNT:-5000000000000000000000}   # 5,000 IP (ether units)
UNDELEGATE_AMOUNT=${UNDELEGATE_AMOUNT:-2600000000000000000000}   # 2,600 IP (ether units)

LOCK_PERIOD=${LOCK_PERIOD:-2}                             # 0=flexible, 1=short, 2=medium, 3=long
VALIDATOR_CONTAINER=${VALIDATOR_CONTAINER:-"validator1-node"}

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
if [[ (-z "${PRIVATE_KEY_OTHER:-}" || -z "${PRIVATE_KEY:-}") && -f "$PRIVATE_KEY_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$PRIVATE_KEY_FILE"
  set +a
fi

if [[ -z "${PRIVATE_KEY_OTHER:-}" ]]; then
  echo "Set PRIVATE_KEY_OTHER in ${PRIVATE_KEY_FILE} (or export it) for the delegator account." >&2
  exit 1
fi

PRIVATE_KEY_STRIPPED=${PRIVATE_KEY#0x}
PRIVATE_KEY_STRIPPED_OTHER=${PRIVATE_KEY_OTHER#0x}

if [[ -n "${PRIVATE_KEY:-}" && ${#PRIVATE_KEY_STRIPPED} -ne 64 ]]; then
  echo "PRIVATE_KEY must be a 32-byte hex string (optionally 0x-prefixed)." >&2
  exit 1
fi

if [[ ${#PRIVATE_KEY_STRIPPED_OTHER} -ne 64 ]]; then
  echo "PRIVATE_KEY_OTHER must be a 32-byte hex string (optionally 0x-prefixed)." >&2
  exit 1
fi

# Resolve validator info
extract_from_lines() {
  local label="$1"
  awk -F': ' -v lbl="$label" '$1 == lbl {print $2}'
}

base64_to_hex() {
  if command -v base64 >/dev/null 2>&1; then
    if base64 --help 2>&1 | grep -q -- '-d'; then
      base64 -d
      return
    fi
    base64 -D
    return
  fi

  python - <<'PY'
import base64, sys
data = sys.stdin.read().strip().encode()
sys.stdout.write(base64.b64decode(data).hex())
PY
}

hex_to_base64() {
  if command -v xxd >/dev/null 2>&1; then
    xxd -r -p | base64
    return
  fi

  python - <<'PY'
import base64, sys
hx = sys.stdin.read().strip()
sys.stdout.write(base64.b64encode(bytes.fromhex(hx)).decode())
PY
}

USER_VAL_PUBKEY_B64=${VAL_PUBKEY_B64:-}
USER_VAL_CMP_PUBKEY=${VAL_CMP_PUBKEY:-}
USER_VAL_ADDRESS_BECH32=${VAL_ADDRESS_BECH32:-}

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required to resolve genesis validator info." >&2
  exit 1
fi

VALIDATOR_EXPORT=$(docker exec -i "$VALIDATOR_CONTAINER" story validator export 2>/dev/null || echo "")
if [[ -z "$VALIDATOR_EXPORT" ]]; then
  echo "Failed to export validator info from ${VALIDATOR_CONTAINER}." >&2
  exit 1
fi

VAL_CMP_PUBKEY=$(echo "$VALIDATOR_EXPORT" | extract_from_lines "Compressed Public Key")
if [[ -z "$VAL_CMP_PUBKEY" ]]; then
  VAL_CMP_PUBKEY=$(echo "$VALIDATOR_EXPORT" | extract_from_lines "Compressed Public Key (hex)")
fi
VAL_ADDRESS_BECH32=$(echo "$VALIDATOR_EXPORT" | extract_from_lines "Validator Address")
VAL_ADDRESS_EVM=$(echo "$VALIDATOR_EXPORT" | extract_from_lines "EVM Address")
VAL_PUBKEY_B64=$(echo "$VALIDATOR_EXPORT" | extract_from_lines "Compressed Public Key (base64)")
if [[ -z "$VAL_PUBKEY_B64" && -n "$VAL_CMP_PUBKEY" ]]; then
  VAL_PUBKEY_B64=$(printf '%s' "${VAL_CMP_PUBKEY#0x}" | hex_to_base64 | tr -d '\r\n')
fi

if [[ -n "${USER_VAL_PUBKEY_B64:-}" && "$USER_VAL_PUBKEY_B64" != "$VAL_PUBKEY_B64" ]]; then
  echo "Validator pubkey override does not match ${VALIDATOR_CONTAINER} export." >&2
  exit 1
fi
if [[ -n "${USER_VAL_CMP_PUBKEY:-}" && "${USER_VAL_CMP_PUBKEY#0x}" != "${VAL_CMP_PUBKEY#0x}" ]]; then
  echo "Validator compressed pubkey override does not match ${VALIDATOR_CONTAINER} export." >&2
  exit 1
fi
if [[ -n "${USER_VAL_ADDRESS_BECH32:-}" && "$USER_VAL_ADDRESS_BECH32" != "$VAL_ADDRESS_BECH32" ]]; then
  echo "Validator bech32 override does not match ${VALIDATOR_CONTAINER} export." >&2
  exit 1
fi

if [[ -z "${VAL_CMP_PUBKEY:-}" ]]; then
  echo "Failed to resolve validator pubkey from ${VALIDATOR_CONTAINER}." >&2
  exit 1
fi

if [[ -z "${VAL_ADDRESS_BECH32:-}" ]]; then
  echo "Failed to resolve validator bech32 address. Set VAL_ADDRESS_BECH32 or ensure ${VALIDATOR_CONTAINER} is running." >&2
  exit 1
fi

echo "Resolved validator info:"
echo "  VALIDATOR_CONTAINER: ${VALIDATOR_CONTAINER}"
echo "  VAL_CMP_PUBKEY: ${VAL_CMP_PUBKEY}"
echo "  VAL_PUBKEY_B64: ${VAL_PUBKEY_B64}"
echo "  VAL_ADDRESS_BECH32: ${VAL_ADDRESS_BECH32}"
echo "  VAL_ADDRESS_EVM: ${VAL_ADDRESS_EVM:-"(unset)"}"

# Get delegator info from PRIVATE_KEY_OTHER
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
  echo "Failed to derive delegator address from PRIVATE_KEY_OTHER. Please set DEL_ADDRESS_BECH32 explicitly." >&2
  exit 1
fi

if [[ -z "$DEL_ADDRESS_EVM" ]]; then
  echo "Failed to derive delegator EVM address from PRIVATE_KEY_OTHER. Please set DEL_ADDRESS_EVM explicitly." >&2
  exit 1
fi

echo "Resolved delegator info:"
echo "  DEL_ADDRESS_BECH32: ${DEL_ADDRESS_BECH32}"
echo "  DEL_ADDRESS_EVM: ${DEL_ADDRESS_EVM}"

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
  
  if [[ -n "$STORY_API" && -n "$val_addr_evm" && -n "$del_addr_evm" ]]; then
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

echo "=== Step 1: Delegator delegates ${DELEGATE_AMOUNT} IP to genesis validator ==="
echo "Using validator pubkey (compressed hex): ${VAL_CMP_PUBKEY}"
echo "Using delegator EVM address: ${DEL_ADDRESS_EVM}"
STAKE_OUTPUT=$(run_validator_cmd_other stake \
  --validator-pubkey "$VAL_CMP_PUBKEY" \
  --stake "${DELEGATE_AMOUNT}" \
  --staking-period "$PERIOD_NAME" \
  --chain-id "$CHAIN_ID" \
  --rpc "$EL_RPC" \
  --explorer "$EXPLORER_URL" \
  --story-api "$STORY_API" 2>&1)
echo "$STAKE_OUTPUT"

DELEGATION_ID=${DELEGATION_ID:-$(echo "$STAKE_OUTPUT" | awk -F': ' '/Delegation ID/ {print $2}' | tail -n 1)}
if [[ -z "${DELEGATION_ID:-}" ]]; then
  echo "Failed to detect delegation ID from stake output. Set DELEGATION_ID explicitly." >&2
  exit 1
fi
sleep 5

echo
echo "=== Step 2: Delegator undelegates ${UNDELEGATE_AMOUNT} IP from genesis validator ==="
echo "Using validator pubkey (compressed hex): ${VAL_CMP_PUBKEY}"
echo "Using delegation ID: ${DELEGATION_ID}"
run_validator_cmd_other unstake \
  --validator-pubkey "$VAL_CMP_PUBKEY" \
  --unstake "${UNDELEGATE_AMOUNT}" \
  --delegation-id "$DELEGATION_ID" \
  --chain-id "$CHAIN_ID" \
  --rpc "$EL_RPC" \
  --explorer "$EXPLORER_URL" \
  --story-api "$STORY_API"
sleep 5

echo
echo "=== Step 3: Check rewards shares of the delegator ==="
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

