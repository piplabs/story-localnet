#!/usr/bin/env bash
set -euo pipefail

# Script to upgrade story binary in all Docker containers
# Usage: ./scripts/upgrade_story_binary.sh [path_to_story_binary]
#
# If binary path is not provided, it will look for:
#   1. ../story/story (relative to story-localnet)
#   2. ./story (in story-localnet directory)
#   3. story (in PATH)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCALNET_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Nodes to upgrade in order (rolling upgrade strategy):
# 1. Validators first (for consensus stability)
# 2. RPC nodes (validator1-node serves as RPC)
# 3. Bootnode last (for network discovery)

VALIDATOR_NODES=(
  "validator1-node"
  "validator2-node"
  # "validator3-node"
  "validator4-node"
)

RPC_NODES=(
  "validator1-node"  # validator1-node also serves as RPC endpoint
)

BOOTNODE_NODES=(
  "bootnode1-node"
)

# Story binary path in container
CONTAINER_BINARY_PATH="/usr/local/bin/story"

# Determine source binary path
if [[ $# -ge 1 ]]; then
  SOURCE_BINARY="$1"
elif [[ -f "$LOCALNET_ROOT/../story/story" ]]; then
  SOURCE_BINARY="$LOCALNET_ROOT/../story/story"
elif [[ -f "$LOCALNET_ROOT/story" ]]; then
  SOURCE_BINARY="$LOCALNET_ROOT/story"
elif command -v story >/dev/null 2>&1; then
  SOURCE_BINARY=$(command -v story)
else
  echo "Error: Story binary not found." >&2
  echo "Please provide the path to the story binary:" >&2
  echo "  $0 <path_to_story_binary>" >&2
  echo "" >&2
  echo "Or place it at one of these locations:" >&2
  echo "  - ../story/story (relative to story-localnet)" >&2
  echo "  - ./story (in story-localnet directory)" >&2
  exit 1
fi

# Validate source binary exists and is executable
if [[ ! -f "$SOURCE_BINARY" ]]; then
  echo "Error: Story binary not found at: $SOURCE_BINARY" >&2
  exit 1
fi

if [[ ! -x "$SOURCE_BINARY" ]]; then
  echo "Warning: Story binary is not executable, attempting to make it executable..." >&2
  chmod +x "$SOURCE_BINARY" || {
    echo "Error: Failed to make binary executable" >&2
    exit 1
  }
fi

# Function to get binary architecture and OS
get_binary_info() {
  local binary="$1"
  local arch="unknown"
  local os="unknown"
  
  if command -v file >/dev/null 2>&1; then
    local file_info
    file_info=$(file "$binary" 2>/dev/null)
    
    # Extract architecture
    if echo "$file_info" | grep -qE "(x86-64|amd64|x86_64)"; then
      arch="amd64"
    elif echo "$file_info" | grep -qE "(aarch64|arm64)"; then
      arch="arm64"
    elif echo "$file_info" | grep -qE "386"; then
      arch="386"
    fi
    
    # Extract OS
    if echo "$file_info" | grep -qE "Mach-O"; then
      os="darwin"
    elif echo "$file_info" | grep -qE "ELF"; then
      os="linux"
    elif echo "$file_info" | grep -qE "PE32"; then
      os="windows"
    fi
  elif command -v go >/dev/null 2>&1; then
    # Try to get arch from go version -m
    local go_info
    go_info=$(go version -m "$binary" 2>/dev/null)
    arch=$(echo "$go_info" | grep -oE "GOARCH=[a-z0-9]+" | cut -d= -f2 || echo "unknown")
    os=$(echo "$go_info" | grep -oE "GOOS=[a-z0-9]+" | cut -d= -f2 || echo "unknown")
  fi
  
  echo "$arch|$os"
}

# Function to get binary architecture (backward compatibility)
get_binary_arch() {
  local binary="$1"
  get_binary_info "$binary" | cut -d'|' -f1
}

# Function to normalize architecture names
normalize_arch() {
  # Strip whitespace and convert to lowercase (compatible with bash 3.x)
  local arch
  arch=$(echo "$1" | tr -d '\r\n ' | tr '[:upper:]' '[:lower:]')
  case "$arch" in
    x86-64|amd64|x86_64) echo "amd64" ;;
    aarch64|arm64|arm64v8) echo "arm64" ;;
    "") echo "unknown" ;;
    *) echo "$arch" ;;
  esac
}

# Function to get container architecture
get_container_arch() {
  local container_name="$1"
  if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    # Try docker inspect first, then uname -m, strip whitespace and newlines
    docker inspect "$container_name" --format '{{.Architecture}}' 2>/dev/null | tr -d '\r\n ' || \
    docker exec "$container_name" uname -m 2>/dev/null | tr -d '\r\n ' || echo "unknown"
  else
    echo "unknown"
  fi
}

# Check binary architecture and OS
echo "Checking binary compatibility..."
BINARY_INFO=$(get_binary_info "$SOURCE_BINARY")
BINARY_ARCH=$(echo "$BINARY_INFO" | cut -d'|' -f1)
BINARY_OS=$(echo "$BINARY_INFO" | cut -d'|' -f2)
BINARY_ARCH_NORM=$(normalize_arch "$BINARY_ARCH")

if [[ "$BINARY_ARCH_NORM" == "unknown" ]]; then
  echo "⚠️  Warning: Could not determine binary architecture"
else
  echo "  Binary architecture: $BINARY_ARCH_NORM"
fi

if [[ "$BINARY_OS" == "unknown" ]]; then
  echo "⚠️  Warning: Could not determine binary OS"
else
  echo "  Binary OS: $BINARY_OS"
fi

# Check OS compatibility (containers run Linux)
if [[ "$BINARY_OS" != "unknown" ]] && [[ "$BINARY_OS" != "linux" ]]; then
  echo ""
  echo "❌ ERROR: Binary OS mismatch!" >&2
  echo "   Binary OS: $BINARY_OS" >&2
  echo "   Required OS: linux" >&2
  echo "" >&2
      echo "   The binary was built for $BINARY_OS, but containers require Linux binaries." >&2
      echo "   Please cross-compile for Linux:" >&2
      echo "" >&2
      if [[ "$BINARY_ARCH_NORM" != "unknown" ]]; then
        echo "   GOOS=linux GOARCH=$BINARY_ARCH_NORM go build -o story ./client" >&2
      else
        echo "   GOOS=linux GOARCH=<arch> go build -o story ./client  # Replace <arch> with arm64 or amd64" >&2
      fi
  exit 1
elif [[ "$BINARY_OS" == "linux" ]]; then
  echo "  ✓ Binary OS is Linux (compatible)"
fi

# Check container architecture (try multiple methods and containers)
CONTAINER_ARCH_NORM="unknown"
CONTAINER_CHECKED=false

# Try to check from running containers first
for node in "${VALIDATOR_NODES[@]}" "${BOOTNODE_NODES[@]}"; do
  if docker ps --format "{{.Names}}" | grep -q "^${node}$"; then
    CONTAINER_ARCH=$(get_container_arch "$node")
    CONTAINER_ARCH_NORM=$(normalize_arch "$CONTAINER_ARCH")
    if [[ "$CONTAINER_ARCH_NORM" != "unknown" ]]; then
      CONTAINER_CHECKED=true
      echo "  Container architecture (from $node): $CONTAINER_ARCH_NORM"
      break
    fi
  fi
done

# If still unknown, try stopped containers
if [[ "$CONTAINER_ARCH_NORM" == "unknown" ]]; then
  for node in "${VALIDATOR_NODES[@]}" "${BOOTNODE_NODES[@]}"; do
    if docker ps -a --format "{{.Names}}" | grep -q "^${node}$"; then
      # Try docker inspect first
      CONTAINER_ARCH=$(docker inspect "$node" --format '{{.Architecture}}' 2>/dev/null || echo "unknown")
      if [[ "$CONTAINER_ARCH" != "unknown" ]] && [[ -n "$CONTAINER_ARCH" ]]; then
        CONTAINER_ARCH_NORM=$(normalize_arch "$CONTAINER_ARCH")
        if [[ "$CONTAINER_ARCH_NORM" != "unknown" ]]; then
          CONTAINER_CHECKED=true
          echo "  Container architecture (from $node): $CONTAINER_ARCH_NORM"
          break
        fi
      fi
    fi
  done
fi

# Verify compatibility if we have both architectures
if [[ "$CONTAINER_CHECKED" == "true" ]] && [[ "$BINARY_ARCH_NORM" != "unknown" ]] && [[ "$CONTAINER_ARCH_NORM" != "unknown" ]]; then
  if [[ "$BINARY_ARCH_NORM" != "$CONTAINER_ARCH_NORM" ]]; then
    echo ""
    echo "❌ ERROR: Architecture mismatch!" >&2
    echo "   Binary architecture: $BINARY_ARCH_NORM" >&2
    echo "   Container architecture: $CONTAINER_ARCH_NORM" >&2
    echo "" >&2
    echo "   The binary architecture does not match the container architecture." >&2
    echo "   Please build the binary for $CONTAINER_ARCH_NORM architecture." >&2
    echo "" >&2
    echo "   Example build command:" >&2
    echo "   GOOS=linux GOARCH=$CONTAINER_ARCH_NORM go build -o story ./client" >&2
    exit 1
  else
    echo "  ✓ Architecture match confirmed"
  fi
elif [[ "$CONTAINER_CHECKED" == "false" ]]; then
  echo "  ⚠️  Warning: Could not determine container architecture"
  echo "  Will proceed, but binary may fail if architecture mismatch"
  echo ""
  read -p "Continue anyway? (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Upgrade cancelled"
    exit 0
  fi
elif [[ "$BINARY_ARCH_NORM" == "unknown" ]]; then
  echo "  ⚠️  Warning: Could not determine binary architecture"
  echo "  Will proceed, but binary may fail if architecture mismatch"
fi

echo ""

# Get binary version info
echo "=========================================="
echo "Story Binary Upgrade Script"
echo "=========================================="
echo ""
echo "Source binary: $SOURCE_BINARY"
echo "Binary size: $(du -h "$SOURCE_BINARY" | cut -f1)"
echo ""

# Try to get version info
if "$SOURCE_BINARY" version >/dev/null 2>&1; then
  echo "Binary version info:"
  "$SOURCE_BINARY" version 2>&1 | sed 's/^/  /' || true
elif "$SOURCE_BINARY" --version >/dev/null 2>&1; then
  echo "Binary version info:"
  "$SOURCE_BINARY" --version 2>&1 | sed 's/^/  /' || true
else
  echo "Warning: Could not get version info from binary"
fi

echo ""
echo "Upgrade order (rolling upgrade):"
echo "  1. Validators:"
for node in "${VALIDATOR_NODES[@]}"; do
  echo "     - $node"
done
echo "  2. RPC nodes:"
for node in "${RPC_NODES[@]}"; do
  echo "     - $node"
done
echo "  3. Bootnodes:"
for node in "${BOOTNODE_NODES[@]}"; do
  echo "     - $node"
done

# Calculate total unique nodes (validator1-node appears in both validators and RPC)
ALL_NODES=("${VALIDATOR_NODES[@]}" "${RPC_NODES[@]}" "${BOOTNODE_NODES[@]}")
# Remove duplicates
declare -a UNIQUE_NODES=()
for node in "${ALL_NODES[@]}"; do
  found=false
  # Handle empty array case
  if [[ ${#UNIQUE_NODES[@]} -gt 0 ]]; then
    for existing in "${UNIQUE_NODES[@]}"; do
      if [[ "$node" == "$existing" ]]; then
        found=true
        break
      fi
    done
  fi
  if [[ "$found" == "false" ]]; then
    UNIQUE_NODES+=("$node")
  fi
done
TOTAL_NODES=${#UNIQUE_NODES[@]}

echo ""
read -p "Do you want to proceed with the upgrade? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Upgrade cancelled by user"
  exit 0
fi

echo ""
echo "=========================================="
echo "Starting upgrade process..."
echo "=========================================="
echo ""

# Function to check if node is healthy
check_node_health() {
  local container_name="$1"
  local max_attempts=30
  local attempt=0
  
  echo "  Waiting for node to be healthy..."
  while [[ $attempt -lt $max_attempts ]]; do
    # Check if container is running
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
      attempt=$((attempt + 1))
      sleep 2
      continue
    fi
    
    # Try to get version info (indicates binary is working)
    if docker exec "$container_name" "$CONTAINER_BINARY_PATH" version >/dev/null 2>&1; then
      echo "  ✓ Node is healthy"
      return 0
    fi
    
    attempt=$((attempt + 1))
    if [[ $((attempt % 5)) -eq 0 ]]; then
      echo "    Still waiting... (attempt $attempt/$max_attempts)"
    fi
    sleep 2
  done
  
  echo "  ⚠️  Warning: Node health check timeout"
  return 1
}

# Function to upgrade a single node (rolling upgrade)
upgrade_node() {
  local container_name="$1"
  local source_binary="$2"
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🔄 Rolling Upgrade: $container_name"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # Check if container exists
  if ! docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    echo "⚠️  Container $container_name does not exist, skipping..."
    return 1
  fi
  
  # Step 1: Stop the container (for rolling upgrade, we stop one at a time)
  local was_running=false
  if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
    echo "  [1/5] Stopping container..."
    docker stop "$container_name" || {
      echo "  ❌ Failed to stop container"
      return 1
    }
    echo "  ✓ Container stopped"
    was_running=true
  else
    echo "  [1/5] Container is not running, will start after upgrade"
  fi
  
  # Step 2: Backup old binary (using docker cp which works on stopped containers)
  echo "  [2/5] Backing up old binary..."
  local backup_tmp=$(mktemp)
  if docker cp "${container_name}:${CONTAINER_BINARY_PATH}" "$backup_tmp" 2>/dev/null; then
    docker cp "$backup_tmp" "${container_name}:${CONTAINER_BINARY_PATH}.backup" 2>/dev/null || true
    rm -f "$backup_tmp"
    echo "  ✓ Backup created"
  else
    echo "  ⚠️  Could not backup old binary (non-critical)"
  fi
  
  # Step 3: Copy new binary into container
  echo "  [3/5] Copying new binary into container..."
  docker cp "$source_binary" "${container_name}:${CONTAINER_BINARY_PATH}" || {
    echo "  ❌ Failed to copy binary into container"
    return 1
  }
  echo "  ✓ Binary copied successfully"
  
  # Step 4: Start container (rolling upgrade: start one at a time)
  if [[ "$was_running" == "true" ]]; then
    echo "  [4/5] Restarting container..."
    docker start "$container_name" || {
      echo "  ❌ Failed to start container"
      echo "  💡 Tip: You can restore the backup with:"
      echo "    docker cp ${container_name}:${CONTAINER_BINARY_PATH}.backup ${container_name}:${CONTAINER_BINARY_PATH}"
      return 1
    }
    
    # Wait for container to start
    sleep 3
    
    # Verify container is running
    local max_wait=10
    local count=0
    while [[ $count -lt $max_wait ]]; do
      if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        break
      fi
      sleep 1
      count=$((count + 1))
    done
    
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
      echo "  ❌ Container failed to start"
      echo "  Check logs with: docker logs $container_name"
      return 1
    fi
    
    echo "  ✓ Container restarted"
  else
    echo "  [4/5] Container was not running, skipping restart"
  fi
  
  # Step 5: Verify and health check
  echo "  [5/5] Verifying upgrade..."
  
  # Set permissions (if container is running)
  if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
    docker exec "$container_name" chmod +x "$CONTAINER_BINARY_PATH" 2>/dev/null || true
    
    # Verify binary is executable
    if docker exec "$container_name" test -x "$CONTAINER_BINARY_PATH" 2>/dev/null; then
      echo "  ✓ Binary is executable"
    else
      echo "  ⚠️  Warning: Could not verify binary permissions"
    fi
    
    # Get version info from new binary
    echo "  New binary version:"
    docker exec "$container_name" "$CONTAINER_BINARY_PATH" version 2>&1 | sed 's/^/    /' || \
    docker exec "$container_name" "$CONTAINER_BINARY_PATH" --version 2>&1 | sed 's/^/    /' || \
    echo "    (version info not available)"
    
    # Health check
    check_node_health "$container_name"
  else
    echo "  ⚠️  Container is not running, skipping verification"
  fi
  
  echo "  ✅ Upgrade completed for $container_name"
  echo ""
  return 0
}

# Rolling upgrade: upgrade nodes in order (validators -> RPC -> bootnode)
SUCCESS_COUNT=0
FAILED_NODES=()

echo "Starting rolling upgrade process..."
echo "This will upgrade nodes one at a time to ensure service availability."
echo ""

# Function to upgrade a group of nodes
upgrade_node_group() {
  local group_name="$1"
  shift
  local nodes=("$@")
  
  if [[ ${#nodes[@]} -eq 0 ]]; then
    return 0
  fi
  
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📦 Upgrading $group_name (${#nodes[@]} node(s))"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  
  for node in "${nodes[@]}"; do
    if upgrade_node "$node" "$SOURCE_BINARY"; then
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      # Wait a bit between nodes to ensure stability
      if [[ $SUCCESS_COUNT -lt $TOTAL_NODES ]]; then
        echo "Waiting 5 seconds before upgrading next node..."
        sleep 5
        echo ""
      fi
    else
      FAILED_NODES+=("$node")
      echo "❌ Upgrade failed for $node"
      echo "   Rolling upgrade stopped. Remaining nodes not upgraded."
      echo ""
      return 1
    fi
  done
  
  return 0
}

# Step 1: Upgrade validators first
if ! upgrade_node_group "Validators" "${VALIDATOR_NODES[@]}"; then
  echo "Failed during validator upgrade phase"
else
  # Step 2: Upgrade RPC nodes (skip validator1-node if already upgraded)
  RPC_TO_UPGRADE=()
  for rpc_node in "${RPC_NODES[@]}"; do
    already_upgraded=false
    for validator_node in "${VALIDATOR_NODES[@]}"; do
      if [[ "$rpc_node" == "$validator_node" ]]; then
        already_upgraded=true
        break
      fi
    done
    if [[ "$already_upgraded" == "false" ]]; then
      RPC_TO_UPGRADE+=("$rpc_node")
    fi
  done
  
  if [[ ${#RPC_TO_UPGRADE[@]} -gt 0 ]]; then
    if ! upgrade_node_group "RPC Nodes" "${RPC_TO_UPGRADE[@]}"; then
      echo "Failed during RPC upgrade phase"
    fi
  else
    echo "RPC nodes already upgraded (overlap with validators)"
    echo ""
  fi
  
  # Step 3: Upgrade bootnodes last
  if [[ ${#FAILED_NODES[@]} -eq 0 ]]; then
    upgrade_node_group "Bootnodes" "${BOOTNODE_NODES[@]}" || true
  fi
fi

# Summary
echo "=========================================="
echo "Upgrade Summary"
echo "=========================================="
echo ""
echo "Successfully upgraded: $SUCCESS_COUNT/$TOTAL_NODES nodes"

if [[ ${#FAILED_NODES[@]} -gt 0 ]]; then
  echo ""
  echo "Failed nodes:"
  for node in "${FAILED_NODES[@]}"; do
    echo "  - $node"
  done
  echo ""
  echo "Please check the logs for failed nodes:"
  for node in "${FAILED_NODES[@]}"; do
    echo "  docker logs $node"
  done
  exit 1
else
  echo ""
  echo "✓ All nodes upgraded successfully!"
  echo ""
  echo "You can check the status of nodes with:"
  echo "  docker ps"
  echo ""
  echo "To view logs:"
  echo "  docker logs -f <container_name>"
fi

