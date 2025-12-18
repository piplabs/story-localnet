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
