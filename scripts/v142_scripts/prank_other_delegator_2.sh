#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   1. Create `.env` (or set env vars) with at least `PRIVATE_KEY=0x...`.
#   2. Prepare story client to localnet root folder
# The script performs: create validator with 110,000 IP -> 
# other stake 220,000 IP ->
# other unstake 105,001 IP

CHAIN_ID=${CHAIN_ID:-1399}
EL_RPC=${EL_RPC:-http://localhost:8545}
EXPLORER_URL=${EXPLORER_URL:-http://localhost:26657}
STORY_API=${STORY_API:-""}

# Financial parameters (all values in wei unless stated otherwise)
CREATE_AMOUNT=${CREATE_AMOUNT:-110000000000000000000000}   # 110,000 IP (ether units)
OTHER_STATKE_AMOUNT=${OTHER_STATKE_AMOUNT:-220000000000000000000000}   # 220,000 IP (ether units)
OTHER_UNSTAKE_AMOUNT=${OTHER_UNSTAKE_AMOUNT:-105001000000000000000000}   # 105,001 IP (ether units)

LOCK_PERIOD=${LOCK_PERIOD:-2}                             # 0=flexible, 1=short, 2=medium, 3=long
MONIKER=${MONIKER:-"staking-0802"}

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

PRIVATE_KEY_STRIPPED=${PRIVATE_KEY#0x}
PRIVATE_KEY_STRIPPED_OTHER=${PRIVATE_KEY_OTHER#0x}

if [[ ${#PRIVATE_KEY_STRIPPED} -ne 64 ]]; then
  echo "PRIVATE_KEY must be a 32-byte hex string (optionally 0x-prefixed)." >&2
  exit 1
fi

TMP_PK_ENV=$(mktemp)
printf "PRIVATE_KEY=%s\n" "$PRIVATE_KEY_STRIPPED" > "$TMP_PK_ENV"
KEY_INFO=$("$STORY_BIN" key convert --private-key-file "$TMP_PK_ENV")
rm -f "$TMP_PK_ENV"

extract_from_key_info() {
  local label="$1"
  echo "$KEY_INFO" | awk -F': ' -v lbl="$label" '$1 == lbl {print $2}'
}

VAL_CMP_PUBKEY=${VAL_CMP_PUBKEY:-$(extract_from_key_info "Compressed Public Key (hex)")}

if [[ -z "$VAL_CMP_PUBKEY" ]]; then
  echo "Failed to derive validator pubkey from PRIVATE_KEY. Please set VAL_CMP_PUBKEY explicitly." >&2
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

echo "=== Step 1: create validator ${CREATE_AMOUNT}  ==="
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
echo "=== Step 2: other stake ${OTHER_STATKE_AMOUNT} ==="
run_validator_cmd_other stake \
  --validator-pubkey "$VAL_CMP_PUBKEY" \
  --stake "${OTHER_STATKE_AMOUNT}" \
  --staking-period "$PERIOD_NAME" \
  --chain-id "$CHAIN_ID" \
  --rpc "$EL_RPC" \
  --explorer "$EXPLORER_URL" \
  --story-api "$STORY_API"
sleep 20

echo
echo "=== Step 3: other unstake ${OTHER_UNSTAKE_AMOUNT} ==="
run_validator_cmd_other unstake \
  --validator-pubkey "$VAL_CMP_PUBKEY" \
  --unstake "${OTHER_UNSTAKE_AMOUNT}" \
  --delegation-id 0 \
  --chain-id "$CHAIN_ID" \
  --rpc "$EL_RPC" \
  --explorer "$EXPLORER_URL" \
  --story-api "$STORY_API"
