#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   1. Create `.env` (or set env vars) with:
#      - `PRIVATE_KEY=0x...` (validator private key, same as in prank_delegator_rewards_shares.sh)
#      - `PRIVATE_KEY_NEW_DELEGATOR3=0x...` (new delegator private key)
#   2. Prepare story client to localnet root folder
# The script performs:
#   1. Get validator info from PRIVATE_KEY
#   2. Get new delegator info from PRIVATE_KEY_NEW_DELEGATOR3
#   3. New delegator delegates 2400 IP token to the validator

CHAIN_ID=${CHAIN_ID:-1399}
EL_RPC=${EL_RPC:-http://localhost:8545}
EXPLORER_URL=${EXPLORER_URL:-http://localhost:26657}
STORY_API=${STORY_API:-""}

# Financial parameters (all values in wei unless stated otherwise)
DELEGATE_AMOUNT=${DELEGATE_AMOUNT:-2400000000000000000000}   # 2,400 IP (ether units)
TRANSFER_AMOUNT=${TRANSFER_AMOUNT:-10000000000000000000000}   # 10,000 IP (ether units) - for gas and stake

LOCK_PERIOD=${LOCK_PERIOD:-2}                             # 0=flexible, 1=short, 2=medium, 3=long

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
  echo "Set PRIVATE_KEY in ${PRIVATE_KEY_FILE} (or export it) for the validator account." >&2
  exit 1
fi

if [[ -z "${PRIVATE_KEY_NEW_DELEGATOR3:-}" ]]; then
  echo "Set PRIVATE_KEY_NEW_DELEGATOR3 in ${PRIVATE_KEY_FILE} (or export it) for the new delegator account." >&2
  exit 1
fi

PRIVATE_KEY_STRIPPED=${PRIVATE_KEY#0x}
PRIVATE_KEY_NEW_DELEGATOR_STRIPPED=${PRIVATE_KEY_NEW_DELEGATOR3#0x}

if [[ ${#PRIVATE_KEY_STRIPPED} -ne 64 ]]; then
  echo "PRIVATE_KEY must be a 32-byte hex string (optionally 0x-prefixed)." >&2
  exit 1
fi

if [[ ${#PRIVATE_KEY_NEW_DELEGATOR_STRIPPED} -ne 64 ]]; then
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

# Get new delegator info from PRIVATE_KEY_NEW_DELEGATOR3
TMP_PK_ENV_NEW=$(mktemp)
printf "PRIVATE_KEY=%s\n" "$PRIVATE_KEY_NEW_DELEGATOR_STRIPPED" > "$TMP_PK_ENV_NEW"
KEY_INFO_NEW=$("$STORY_BIN" key convert --private-key-file "$TMP_PK_ENV_NEW")
rm -f "$TMP_PK_ENV_NEW"

extract_from_key_info_new() {
  local label="$1"
  echo "$KEY_INFO_NEW" | awk -F': ' -v lbl="$label" '$1 == lbl {print $2}'
}

NEW_DEL_ADDRESS_BECH32=${NEW_DEL_ADDRESS_BECH32:-$(extract_from_key_info_new "Delegator Address")}
NEW_DEL_ADDRESS_EVM=${NEW_DEL_ADDRESS_EVM:-$(extract_from_key_info_new "EVM Address")}

if [[ -z "$NEW_DEL_ADDRESS_BECH32" ]]; then
  echo "Failed to derive new delegator address from PRIVATE_KEY_NEW_DELEGATOR3. Please set NEW_DEL_ADDRESS_BECH32 explicitly." >&2
  exit 1
fi

if [[ -z "$NEW_DEL_ADDRESS_EVM" ]]; then
  echo "Failed to derive new delegator EVM address from PRIVATE_KEY_NEW_DELEGATOR3. Please set NEW_DEL_ADDRESS_EVM explicitly." >&2
  exit 1
fi

run_validator_cmd_new_delegator() {
  PRIVATE_KEY="$PRIVATE_KEY_NEW_DELEGATOR_STRIPPED" "$STORY_BIN" validator "$@"
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

# Function to transfer tokens using Python eth_account and curl
transfer_tokens() {
  local from_priv_key="$1"
  local to_address="$2"
  local amount_wei="$3"
  local rpc_url="${4:-$EL_RPC}"
  
  # Check if eth_account is available
  if ! python3 -c "from eth_account import Account" 2>/dev/null; then
    echo "" >&2
    echo "Error: eth_account Python library not found." >&2
    echo "" >&2
    echo "Please install it with one of the following:" >&2
    echo "  python3 -m pip install --break-system-packages eth-account" >&2
    echo "  or (if using virtual environment):" >&2
    echo "  pip install eth-account" >&2
    echo "" >&2
    return 1
  fi
  
  python3 <<PYTHON
from eth_account import Account
import json
import subprocess
import sys
import time

rpc_url = "$rpc_url"
from_priv_key = "$from_priv_key".lstrip('0x')
to_address = "$to_address"
amount_wei = int("$amount_wei")
chain_id = $CHAIN_ID

try:
    account = Account.from_key(from_priv_key)
    from_address = account.address
    
    # Get nonce
    nonce_req = {
        "jsonrpc": "2.0",
        "method": "eth_getTransactionCount",
        "params": [from_address, "pending"],
        "id": 1
    }
    nonce_resp = subprocess.run(
        ["curl", "-s", "-X", "POST", rpc_url, "-H", "Content-Type: application/json", "-d", json.dumps(nonce_req)],
        capture_output=True, text=True, check=True
    )
    nonce_hex = json.loads(nonce_resp.stdout)["result"]
    nonce = int(nonce_hex, 16)
    
    # Get gas price
    gas_price_req = {
        "jsonrpc": "2.0",
        "method": "eth_gasPrice",
        "params": [],
        "id": 2
    }
    gas_price_resp = subprocess.run(
        ["curl", "-s", "-X", "POST", rpc_url, "-H", "Content-Type: application/json", "-d", json.dumps(gas_price_req)],
        capture_output=True, text=True, check=True
    )
    gas_price_hex = json.loads(gas_price_resp.stdout)["result"]
    gas_price = int(gas_price_hex, 16)
    
    # Build transaction
    tx = {
        'nonce': nonce,
        'to': to_address,
        'value': amount_wei,
        'gas': 21000,
        'gasPrice': gas_price,
        'chainId': chain_id
    }
    
    # Sign transaction
    signed_tx = account.sign_transaction(tx)
    raw_tx_hex = '0x' + signed_tx.raw_transaction.hex()
    
    # Send transaction
    send_req = {
        "jsonrpc": "2.0",
        "method": "eth_sendRawTransaction",
        "params": [raw_tx_hex],
        "id": 3
    }
    send_resp = subprocess.run(
        ["curl", "-s", "-X", "POST", rpc_url, "-H", "Content-Type: application/json", "-d", json.dumps(send_req)],
        capture_output=True, text=True, check=True
    )
    send_result = json.loads(send_resp.stdout)
    
    if "error" in send_result:
        print(f"Error: {send_result['error']}", file=sys.stderr)
        sys.exit(1)
    
    tx_hash = send_result["result"]
    print(f"Transaction sent: {tx_hash}")
    print(f"Waiting for confirmation...")
    
    # Wait for transaction receipt
    max_wait = 60
    waited = 0
    while waited < max_wait:
        receipt_req = {
            "jsonrpc": "2.0",
            "method": "eth_getTransactionReceipt",
            "params": [tx_hash],
            "id": 4
        }
        receipt_resp = subprocess.run(
            ["curl", "-s", "-X", "POST", rpc_url, "-H", "Content-Type: application/json", "-d", json.dumps(receipt_req)],
            capture_output=True, text=True, check=True
        )
        receipt_result = json.loads(receipt_resp.stdout)
        
        if receipt_result.get("result") is not None:
            receipt = receipt_result["result"]
            status = int(receipt["status"], 16)
            if status == 1:
                print(f"✓ Transfer successful: {amount_wei / 10**18} IP")
                sys.exit(0)
            else:
                print("Error: Transaction failed", file=sys.stderr)
                sys.exit(1)
        
        time.sleep(2)
        waited += 2
    
    print("Warning: Transaction sent but confirmation timeout", file=sys.stderr)
    print(f"Transaction hash: {tx_hash}", file=sys.stderr)
    sys.exit(0)
    
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON
}

run_validator_cmd() {
  PRIVATE_KEY="$PRIVATE_KEY_STRIPPED" "$STORY_BIN" validator "$@"
}

echo "=== Validator Information ==="
echo "Validator Address (bech32): $VAL_ADDRESS_BECH32"
echo "Validator Address (EVM): $VAL_ADDRESS_EVM"
echo "Validator Compressed Public Key: $VAL_CMP_PUBKEY"
echo ""

echo "=== New Delegator Information ==="
echo "New Delegator Address (bech32): $NEW_DEL_ADDRESS_BECH32"
echo "New Delegator Address (EVM): $NEW_DEL_ADDRESS_EVM"
echo ""

echo "=== Step 1: Validator transfers ${TRANSFER_AMOUNT} IP to new delegator ==="
echo "Transferring funds from validator to new delegator for gas and stake..."
transfer_tokens "$PRIVATE_KEY_STRIPPED" "$NEW_DEL_ADDRESS_EVM" "$TRANSFER_AMOUNT" "$EL_RPC"
sleep 2

echo ""
echo "=== Step 2: New delegator delegates ${DELEGATE_AMOUNT} IP to validator ==="
run_validator_cmd_new_delegator stake \
  --validator-pubkey "$VAL_CMP_PUBKEY" \
  --stake "${DELEGATE_AMOUNT}" \
  --staking-period "$PERIOD_NAME" \
  --chain-id "$CHAIN_ID" \
  --rpc "$EL_RPC" \
  --explorer "$EXPLORER_URL" \
  --story-api "$STORY_API"

echo ""
echo "✓ SUCCESS: New delegator has staked ${DELEGATE_AMOUNT} IP to the validator"
echo ""
