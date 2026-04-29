#!/bin/bash

# Suppress orphan container warnings (multiple compose files share same project)
export COMPOSE_IGNORE_ORPHANS=true

echo "🚀 Starting Story Localnet..."

# Build images if they don't exist (build specific services to avoid parallel conflicts)
if ! docker image inspect story-geth:localnet >/dev/null 2>&1; then
    echo "🔨 Building story-geth image..."
    docker compose -f docker-compose-bootnode1.yml build bootnode1-geth
fi
if ! docker image inspect story-node:localnet >/dev/null 2>&1; then
    echo "🔨 Building story-node image..."
    docker compose -f docker-compose-bootnode1.yml build bootnode1-node
fi

# Verify image binary matches the staged one (catches stale story-prebuilt /
# wrong build context / cached image scenarios). Sentinel is written by
# scripts/stage_binary.sh; if absent, this check is a soft warning instead
# of a hard fail so the existing flow without staging still works.
SENTINEL="$(pwd)/tmp/staged_binary.sha256"
if [[ -f "$SENTINEL" ]]; then
    EXPECTED=$(cat "$SENTINEL")
    docker create --name verify-binary-tmp story-node:localnet >/dev/null
    docker cp verify-binary-tmp:/usr/local/bin/story /tmp/__story_in_image >/dev/null
    docker rm verify-binary-tmp >/dev/null
    ACTUAL=$(shasum -a 256 /tmp/__story_in_image | awk '{print $1}')
    rm -f /tmp/__story_in_image
    if [[ "$EXPECTED" != "$ACTUAL" ]]; then
        echo "❌ ERROR: image binary sha256 mismatch."
        echo "   expected (from $SENTINEL): $EXPECTED"
        echo "   actual   (from running image):  $ACTUAL"
        echo "   the image was likely built from a stale story-prebuilt; rerun scripts/stage_binary.sh + force rebuild."
        exit 1
    fi
    echo "✅ image binary matches staged binary (sha256 ${ACTUAL:0:16}...)"
else
    echo "⚠️  no $SENTINEL — skipping image-binary verification."
    echo "    run scripts/stage_binary.sh <path-to-linux-binary> first to enable this check."
fi

# Start monitoring
docker compose -f docker-compose-monitoring.yml up -d

# Start bootnode (no build needed, images already exist)
docker compose -f docker-compose-bootnode1.yml up -d --no-build
sleep 5

# Start validators (no build needed, images already exist)
docker compose -f docker-compose-validator1.yml up -d --no-build
docker compose -f docker-compose-validator2.yml up -d --no-build
docker compose -f docker-compose-validator3.yml up -d --no-build
docker compose -f docker-compose-validator4.yml up -d --no-build

# Start RPC node
echo "🔗 Starting RPC node..."
docker compose -f docker-compose-rpc1.yml up -d --no-build

# Wait for RPC to be ready
echo "⏳ Waiting for RPC to be ready..."
until curl -s http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -qE '"result":"0x[1-9a-fA-F]'; do
    echo "   Waiting for blocks..."
    sleep 3
done
echo "✅ RPC is ready and producing blocks"

# Start Blockscout
echo "🔍 Starting Blockscout..."
cd blockscout && docker compose up -d
cd ..

# Wait for Blockscout to be ready
echo "⏳ Waiting for Blockscout to be ready..."
until curl -s http://localhost:3080/api/v2/blocks 2>/dev/null | grep -q '"height"'; do
    echo "   Waiting for Blockscout..."
    sleep 5
done
echo "✅ Blockscout is ready"

echo "✅ Story Localnet started!"
echo ""
echo "📍 Endpoints:"
echo "   RPC HTTP:     http://localhost:8545"
echo "   RPC WS:       ws://localhost:8546"
echo "   Blockscout:   http://localhost:3080"
echo "   Grafana:      http://localhost:3000"
