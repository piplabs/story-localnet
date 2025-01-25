#!/bin/bash

STORY_GETH_DIR="../story-geth-private-fork"
GETH_BINARY="$STORY_GETH_DIR/build/bin/geth"

GENESIS_GETH="./config/story/genesis-geth.json"
GENESIS_NODE="./config/story/genesis-node.json"

# Build geth
if [ ! -f "$GETH_BINARY" ]; then
  echo "Building geth binary..."
  pushd "$STORY_GETH_DIR" > /dev/null || exit 1
  make geth
  if [ $? -ne 0 ]; then
    echo "Error: Failed to build geth binary."
    exit 1
  fi
  popd > /dev/null || exit 1
fi

if [ -z "$GENESIS_GETH" ]; then
  echo "Usage: $0 <path-to-genesis.json>"
  exit 1
fi

# Make temporal data dir
TEMP_DATA_DIR=$(mktemp -d)

# Init geth
geth --datadir "$TEMP_DATA_DIR" init "$GENESIS_GETH" &> /dev/null

if [ $? -ne 0 ]; then
  echo "Error: Failed to initialize geth with the provided genesis.json"
  rm -rf "$TEMP_DATA_DIR"
  exit 1
fi

# Get genesis block hash (hex encoded)
GENESIS_HASH=$(geth --datadir "$TEMP_DATA_DIR" console --exec 'eth.getBlock(0).hash' 2>/dev/null | tr -d '"')

if [ -z "$GENESIS_HASH" ]; then
  echo "Error: Failed to extract genesis block hash"
  rm -rf "$TEMP_DATA_DIR"
  exit 1
fi

# Base64 encoding
ENCODED_HASH=$(echo -n "$GENESIS_HASH" | xxd -r -p | base64)

# Remove temp data dir
rm -rf "$TEMP_DATA_DIR"

if [ ! -f "$GENESIS_NODE" ]; then
  echo "Error: genesis-node.json file not found at $GENESIS_NODE"
  exit 1
fi

# Update genesis-node.json file for CL
UPDATED_JSON=$(cat "$GENESIS_NODE" | jq --arg newHash "$ENCODED_HASH" \
  '.app_state.evmengine.params.execution_block_hash = $newHash')

if [ $? -ne 0 ]; then
  echo "Error: Failed to update genesis-node.json"
  exit 1
fi

echo "$UPDATED_JSON" > "$GENESIS_NODE"

echo "Genesis Block Hash (base64 encoded): $ENCODED_HASH"
echo "Updated $GENESIS_NODE with new execution_block_hash."