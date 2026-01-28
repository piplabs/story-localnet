#!/usr/bin/env bash
set -euo pipefail

# Script to check delegator balance
# Usage: ./scripts/check_delegator_balance.sh [delegator_address] [options]
#
# Options:
#   --historical, -h [target_block]  Check historical balance up to target_block
#                                     (automatically continues monitoring new blocks after completion)
#   --start-block, -s <block>        Start checking from this block (requires --historical)
#   --interval, -i <num>              Check every N blocks (default: 10)
#   --watch, -w                      Explicitly enable monitoring (enabled by default in historical mode)
#   --no-watch                       Disable automatic monitoring after historical check
#
# If delegator address is not provided, it will try to get from PRIVATE_KEY_OTHER
# or from environment variables

CHAIN_ID=${CHAIN_ID:-1399}
EL_RPC=${EL_RPC:-http://localhost:8545}

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
if [[ -z "${PRIVATE_KEY_OTHER:-}" && -f "$PRIVATE_KEY_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$PRIVATE_KEY_FILE"
  set +a
fi

# Parse arguments first to check for flags
HISTORICAL_MODE=false
WATCH_MODE=false
NO_WATCH=false
TARGET_BLOCK=""
START_BLOCK=0
INTERVAL=10
DELEGATOR_ADDRESS=""

# Find address argument (non-flag argument that looks like an address)
for arg in "$@"; do
  if [[ ! "$arg" =~ ^-- ]] && [[ ! "$arg" =~ ^-[^-] ]] && [[ "$arg" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
    DELEGATOR_ADDRESS="$arg"
    break
  fi
done

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --historical|--hist|-h)
      HISTORICAL_MODE=true
      if [[ $# -gt 1 ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
        TARGET_BLOCK="$2"
        shift
      fi
      ;;
    --start-block|--from-block|-s)
      if [[ $# -gt 1 ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
        START_BLOCK="$2"
        shift
      else
        echo "Error: --start-block requires a numeric block number" >&2
        exit 1
      fi
      ;;
    --interval|-i)
      if [[ $# -gt 1 ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
        INTERVAL="$2"
        shift
      else
        echo "Error: --interval requires a numeric value" >&2
        exit 1
      fi
      ;;
    --watch|--monitor|-w)
      WATCH_MODE=true
      ;;
    --no-watch|--no-monitor)
      NO_WATCH=true
      ;;
  esac
  shift
done

# Get delegator address from argument, env var, or derive from PRIVATE_KEY_OTHER
if [[ -n "$DELEGATOR_ADDRESS" ]]; then
  # Address found in arguments
  :
elif [[ -n "${DELEGATOR_ADDRESS:-}" ]]; then
  # Use from environment
  :
elif [[ -n "${PRIVATE_KEY_OTHER:-}" ]]; then
  # Derive from PRIVATE_KEY_OTHER
  PRIVATE_KEY_STRIPPED_OTHER=${PRIVATE_KEY_OTHER#0x}
  
  if [[ ${#PRIVATE_KEY_STRIPPED_OTHER} -ne 64 ]]; then
    echo "Error: PRIVATE_KEY_OTHER must be a 32-byte hex string (optionally 0x-prefixed)." >&2
    exit 1
  fi
  
  TMP_PK_ENV_OTHER=$(mktemp)
  printf "PRIVATE_KEY=%s\n" "$PRIVATE_KEY_STRIPPED_OTHER" > "$TMP_PK_ENV_OTHER"
  KEY_INFO_OTHER=$("$STORY_BIN" key convert --private-key-file "$TMP_PK_ENV_OTHER")
  rm -f "$TMP_PK_ENV_OTHER"
  
  extract_from_key_info_other() {
    local label="$1"
    echo "$KEY_INFO_OTHER" | awk -F': ' -v lbl="$label" '$1 == lbl {print $2}'
  }
  
  DELEGATOR_ADDRESS_BECH32=$(extract_from_key_info_other "Delegator Address")
  DELEGATOR_ADDRESS_EVM=$(extract_from_key_info_other "EVM Address")
  DELEGATOR_ADDRESS="$DELEGATOR_ADDRESS_EVM"
else
  echo "Error: Please provide delegator address as argument or set DELEGATOR_ADDRESS or PRIVATE_KEY_OTHER" >&2
  echo "Usage: $0 [delegator_address]" >&2
  exit 1
fi

# Function to convert wei to ether (IP token)
wei_to_ether() {
  local wei="$1"
  python3 -c "print('{:.6f}'.format($wei / 10**18))" 2>/dev/null || echo "$wei"
}

# Function to get EVM balance at a specific block
get_evm_balance() {
  local address="$1"
  local block="${2:-latest}"  # Default to "latest" if not specified
  local response
  response=$(curl -s -X POST "$EL_RPC" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$address\",\"$block\"],\"id\":1}" 2>/dev/null)
  
  # Check for errors
  if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
    local error_msg
    error_msg=$(echo "$response" | jq -r '.error.message' 2>/dev/null || echo "unknown error")
    echo "ERROR: $error_msg" >&2
    echo "0"
    return 1
  fi
  
  local balance_hex
  balance_hex=$(echo "$response" | jq -r '.result' 2>/dev/null || echo "0x0")
  
  if [[ "$balance_hex" == "null" ]] || [[ -z "$balance_hex" ]] || [[ "$balance_hex" == "0x0" ]]; then
    echo "0"
    return
  fi
  
  # Convert hex to decimal
  python3 -c "print(int('$balance_hex', 16))" 2>/dev/null || echo "0"
}

# Function to convert block number to hex
block_to_hex() {
  local block="$1"
  python3 -c "print(hex($block))" 2>/dev/null || echo "0x0"
}

# Function to get current block number
get_block_number() {
  curl -s -X POST "$EL_RPC" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | \
    jq -r '.result' 2>/dev/null | \
    python3 -c "import sys; print(int(sys.stdin.read().strip(), 16))" 2>/dev/null || echo "0"
}

# Normalize address (add 0x prefix if missing)
if [[ ! "$DELEGATOR_ADDRESS" =~ ^0x ]]; then
  DELEGATOR_ADDRESS="0x$DELEGATOR_ADDRESS"
fi

# If historical mode, show balance history
if [[ "$HISTORICAL_MODE" == "true" ]]; then
  # Get current block if target not specified
  if [[ -z "$TARGET_BLOCK" ]]; then
    TARGET_BLOCK=$(get_block_number)
  fi
  
  echo "=========================================="
  echo "Delegator Balance History"
  echo "=========================================="
  echo ""
  echo "Delegator Address (EVM): $DELEGATOR_ADDRESS"
  if [[ -n "${DELEGATOR_ADDRESS_BECH32:-}" ]]; then
    echo "Delegator Address (bech32): $DELEGATOR_ADDRESS_BECH32"
  fi
  echo "RPC Endpoint: $EL_RPC"
  echo "Chain ID: $CHAIN_ID"
  echo ""
  # Validate start block
  if [[ $START_BLOCK -gt $TARGET_BLOCK ]]; then
    echo "Error: Start block ($START_BLOCK) cannot be greater than target block ($TARGET_BLOCK)" >&2
    exit 1
  fi
  
  echo "Checking balance every $INTERVAL blocks from block $START_BLOCK to block $TARGET_BLOCK"
  echo ""
  echo "⚠️  Note: Historical balance queries require the node to support state history."
  echo "   If you see errors, the node may not have archive mode enabled."
  echo "   To enable: Set NoPruning=true or use --gcmode=archive in geth config"
  echo ""
  echo "Block    | Balance (Wei)              | Balance (IP)        | Change (IP)"
  echo "---------|----------------------------|--------------------|----------------"
  
  PREVIOUS_BALANCE_WEI=""
  ERROR_COUNT=0
  SUCCESS_COUNT=0
  CONSECUTIVE_ERRORS=0
  MAX_CONSECUTIVE_ERRORS=3  # If 3 consecutive blocks fail, switch to monitoring mode
  
  # Temporarily disable exit on error for the historical query loop
  # This ensures we can handle errors gracefully and continue to monitoring mode
  set +e
  
  # Get current block to know when to switch to monitoring
  CURRENT_BLOCK_NOW=$(get_block_number || echo "0")
  
  for ((block=START_BLOCK; block<=TARGET_BLOCK; block+=INTERVAL)); do
    # If we've hit too many consecutive errors and current block is beyond our target,
    # switch to monitoring mode early
    if [[ $CONSECUTIVE_ERRORS -ge $MAX_CONSECUTIVE_ERRORS ]] && [[ $CURRENT_BLOCK_NOW -gt $TARGET_BLOCK ]]; then
      echo ""
      echo "⚠️  Too many consecutive errors. Switching to monitoring mode..."
      echo "   Will wait for new blocks to appear."
      break
    fi
    
    # Wait for block to be available if it hasn't been produced yet
    while true; do
      CURRENT_BLOCK_NOW=$(get_block_number 2>/dev/null || echo "0")
      
      # If current block is less than the block we want to query, wait for it
      if [[ $CURRENT_BLOCK_NOW -lt $block ]]; then
        # Block not yet produced, wait and retry
        sleep 1
        continue
      else
        # Block is available (or past), proceed with query
        break
      fi
    done
    
    # Get block hex (with error handling to prevent script exit)
    block_hex=$(block_to_hex "$block" 2>/dev/null || echo "0x0")
    
    # Get balance at this block (with error handling)
    balance_result=$(get_evm_balance "$DELEGATOR_ADDRESS" "$block_hex" 2>&1 || echo "ERROR: Failed to query")
    balance_wei=$(echo "$balance_result" | grep -v "ERROR:" || echo "0")
    
    # Check if we got an error
    if echo "$balance_result" | grep -q "ERROR:"; then
      # Block exists but query failed - likely historical data not available
      ERROR_COUNT=$((ERROR_COUNT + 1))
      CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
      if [[ $ERROR_COUNT -eq 1 ]]; then
        echo ""
        echo "⚠️  Warning: Historical balance queries not supported for some blocks"
        echo "   This usually means the node doesn't have archive mode enabled."
        echo "   Will continue querying, then switch to monitoring new blocks..."
        echo ""
      fi
      # Mark as unavailable
      balance_wei="UNAVAILABLE"
      balance_ether="N/A"
      change_str="N/A"
    else
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      CONSECUTIVE_ERRORS=0  # Reset consecutive error count on success
      balance_ether=$(wei_to_ether "$balance_wei" 2>/dev/null || echo "0")
      
      # Calculate change (always show, even if 0)
      change_str=""
      if [[ -n "$PREVIOUS_BALANCE_WEI" ]] && [[ "$PREVIOUS_BALANCE_WEI" != "" ]] && [[ "$PREVIOUS_BALANCE_WEI" != "UNAVAILABLE" ]]; then
        # Use Python for large number arithmetic to avoid overflow
        diff_info=$(python3 -c "
try:
    balance_wei = int('$balance_wei')
    prev_wei = int('$PREVIOUS_BALANCE_WEI')
    diff_wei = balance_wei - prev_wei
    diff_ether = diff_wei / 10**18
    if diff_wei > 0:
        print(f'+{diff_ether:.6f}')
    elif diff_wei < 0:
        print(f'{diff_ether:.6f}')
    else:
        print('0.000000')
except:
    print('0.000000')
" 2>/dev/null || echo "0.000000")
        change_str="$diff_info"
      else
        change_str="-"
      fi
    fi
    
    # Format output
    if [[ "$balance_wei" == "UNAVAILABLE" ]]; then
      printf "%-8d | %-26s | %-18s | %s\n" "$block" "N/A (not supported)" "N/A" "N/A"
    else
      printf "%-8d | %-26s | %-18s | %s\n" "$block" "$balance_wei" "$balance_ether IP" "$change_str"
      PREVIOUS_BALANCE_WEI="$balance_wei"
    fi
    
    # Small delay to avoid overwhelming RPC
    sleep 0.1
  done
  
  # Re-enable exit on error for the rest of the script
  set -e
  
  echo ""
  # Calculate checked blocks for display (with error handling)
  CHECKED_BLOCKS="$START_BLOCK"
  for ((b=START_BLOCK+INTERVAL; b<=TARGET_BLOCK; b+=INTERVAL)); do
    CHECKED_BLOCKS="$CHECKED_BLOCKS, $b"
  done
  echo "Done. Checked blocks: $CHECKED_BLOCKS"
  echo "Successfully queried: $SUCCESS_COUNT blocks"
  if [[ $ERROR_COUNT -gt 0 ]]; then
    echo "Failed queries: $ERROR_COUNT blocks (historical state not available)"
    echo ""
    echo "To enable historical queries, you need to:"
    echo "  1. Set NoPruning=true in geth.toml config"
    echo "  2. Or use --gcmode=archive when starting geth"
    echo "  3. Restart the node"
  fi
  
  # ALWAYS continue monitoring new blocks after historical query (unless --no-watch)
  # This ensures the script never exits after historical query
  if [[ "$NO_WATCH" == "true" ]]; then
    exit 0
  fi
  
  # Start continuous monitoring - this will run forever until Ctrl+C
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🔄 Starting continuous monitoring mode..."
  echo "   Monitoring new blocks every $INTERVAL block(s)"
  echo "   Press Ctrl+C to stop"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  # Get the last successfully checked block and balance
  # Use the last block we actually checked, or current block if we switched early
  LAST_CHECKED_BLOCK=$TARGET_BLOCK
  CURRENT_BLOCK_NOW=$(get_block_number || echo "0")
  if [[ $CURRENT_BLOCK_NOW -gt $TARGET_BLOCK ]]; then
    # If we're past the target block, start monitoring from current block
    LAST_CHECKED_BLOCK=$CURRENT_BLOCK_NOW
  fi
  LAST_BALANCE_WEI="$PREVIOUS_BALANCE_WEI"
  
  # If we don't have a previous balance, get current balance as baseline
  if [[ -z "$LAST_BALANCE_WEI" ]] || [[ "$LAST_BALANCE_WEI" == "UNAVAILABLE" ]] || [[ "$LAST_BALANCE_WEI" == "" ]]; then
    echo "Getting current balance as baseline..."
    current_balance_result=$(get_evm_balance "$DELEGATOR_ADDRESS" "latest" 2>&1 || true)
    LAST_BALANCE_WEI=$(echo "$current_balance_result" | grep -v "ERROR:" || echo "")
    if [[ -n "$LAST_BALANCE_WEI" ]] && [[ "$LAST_BALANCE_WEI" != "" ]]; then
      current_balance_ether=$(wei_to_ether "$LAST_BALANCE_WEI" || echo "0")
      echo "Current balance: $LAST_BALANCE_WEI wei ($current_balance_ether IP)"
    fi
    echo ""
  fi
  
  # Trap Ctrl+C to exit gracefully
  trap 'echo ""; echo "Monitoring stopped."; exit 0' INT TERM
  
  # Infinite loop - will run forever until interrupted
  # Disable exit on error for monitoring loop to ensure it keeps running
  set +e
  while true; do
    # Use || true to prevent set -e from exiting on errors
    CURRENT_BLOCK=$(get_block_number 2>/dev/null || echo "0")
    
    # Check if we have new blocks to monitor
    if [[ $CURRENT_BLOCK -gt $LAST_CHECKED_BLOCK ]]; then
      # Check every INTERVAL blocks
      NEXT_CHECK_BLOCK=$((LAST_CHECKED_BLOCK + INTERVAL))
      
      if [[ $CURRENT_BLOCK -ge $NEXT_CHECK_BLOCK ]]; then
        block_hex=$(block_to_hex "$NEXT_CHECK_BLOCK" 2>/dev/null || echo "0x0")
        balance_result=$(get_evm_balance "$DELEGATOR_ADDRESS" "$block_hex" 2>&1 || echo "ERROR: Failed to get balance")
        balance_wei=$(echo "$balance_result" | grep -v "ERROR:" || echo "0")
        
        if ! echo "$balance_result" | grep -q "ERROR:"; then
          balance_ether=$(wei_to_ether "$balance_wei" 2>/dev/null || echo "0")
          
          # Calculate change
          change_str=""
          if [[ -n "$LAST_BALANCE_WEI" ]] && [[ "$LAST_BALANCE_WEI" != "" ]] && [[ "$LAST_BALANCE_WEI" != "UNAVAILABLE" ]]; then
            diff_info=$(python3 -c "
try:
    balance_wei = int('$balance_wei')
    prev_wei = int('$LAST_BALANCE_WEI')
    diff_wei = balance_wei - prev_wei
    diff_ether = diff_wei / 10**18
    if diff_wei > 0:
        print(f'+{diff_ether:.6f}')
    elif diff_wei < 0:
        print(f'{diff_ether:.6f}')
    else:
        print('0.000000')
except:
    print('0.000000')
" 2>/dev/null || echo "0.000000")
            change_str="$diff_info"
          else
            change_str="-"
          fi
          
          printf "%-8d | %-26s | %-18s | %s\n" "$NEXT_CHECK_BLOCK" "$balance_wei" "$balance_ether IP" "$change_str"
          LAST_BALANCE_WEI="$balance_wei"
          LAST_CHECKED_BLOCK=$NEXT_CHECK_BLOCK
        else
          # Query failed, but continue waiting for next block
          # Don't print anything to avoid spam, just wait
          :
        fi
      fi
    fi
    
    # Sleep a bit before checking again (check every second)
    # This keeps the loop running even when there are no new blocks or queries fail
    sleep 1
  done
  set -e
  
  # This line should never be reached, but just in case
  exit 0
fi

# Normal mode: current balance check
echo "=========================================="
echo "Delegator Balance Check"
echo "=========================================="
echo ""
echo "Delegator Address (EVM): $DELEGATOR_ADDRESS"
if [[ -n "${DELEGATOR_ADDRESS_BECH32:-}" ]]; then
  echo "Delegator Address (bech32): $DELEGATOR_ADDRESS_BECH32"
fi
echo "RPC Endpoint: $EL_RPC"
echo "Chain ID: $CHAIN_ID"
echo ""

# Get current block
BLOCK_NUMBER=$(get_block_number)
echo "Current Block: $BLOCK_NUMBER"
echo ""

# Get balance
BALANCE_WEI=$(get_evm_balance "$DELEGATOR_ADDRESS" "latest")
BALANCE_ETHER=$(wei_to_ether "$BALANCE_WEI")

echo "Balance:"
echo "  Wei:    $BALANCE_WEI"
echo "  IP:     $BALANCE_ETHER IP"
echo ""

# If there's a previous balance file, compare
BALANCE_FILE="/tmp/delegator_balance_$(echo "$DELEGATOR_ADDRESS" | tr '[:upper:]' '[:lower:]').txt"
if [[ -f "$BALANCE_FILE" ]]; then
  PREVIOUS_BALANCE_WEI=$(cat "$BALANCE_FILE")
  PREVIOUS_BALANCE_ETHER=$(wei_to_ether "$PREVIOUS_BALANCE_WEI")
  DIFF_WEI=$((BALANCE_WEI - PREVIOUS_BALANCE_WEI))
  DIFF_ETHER=$(python3 -c "print('{:.6f}'.format($DIFF_WEI / 10**18))" 2>/dev/null || echo "$DIFF_WEI")
  
  echo "Previous Balance:"
  echo "  Wei:    $PREVIOUS_BALANCE_WEI"
  echo "  IP:     $PREVIOUS_BALANCE_ETHER IP"
  echo ""
  echo "Change:"
  if [[ $DIFF_WEI -gt 0 ]]; then
    echo "  +$DIFF_WEI wei (+$DIFF_ETHER IP)"
  elif [[ $DIFF_WEI -lt 0 ]]; then
    echo "  $DIFF_WEI wei ($DIFF_ETHER IP)"
  else
    echo "  No change"
  fi
  echo ""
fi

# Save current balance for next comparison
echo "$BALANCE_WEI" > "$BALANCE_FILE"
echo "Balance saved to $BALANCE_FILE for next comparison"
echo ""
echo "To check balance again, run: $0 $DELEGATOR_ADDRESS"
echo "To check historical balance (auto-monitors after completion), run:"
echo "  Example: $0 $DELEGATOR_ADDRESS --historical 1000"
echo "  Example: $0 $DELEGATOR_ADDRESS -h 1000 -i 10  # Check every 10 blocks, then monitor"
echo "  Example: $0 $DELEGATOR_ADDRESS -h 1000 -s 190 -i 1  # From block 190, check every block, then monitor"
echo ""
echo "Note: Historical mode automatically continues monitoring new blocks after completion."
echo "      Use --no-watch to disable automatic monitoring."

