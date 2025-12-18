#!/bin/bash

COMPOSE_FILES=(
    "rpc1"
    "bootnode1"
    "validator1"
    "validator2"
    "validator3"
    "validator4"
    "monitoring"
)

stop_container() {
    local file=$1
    echo "Stopping $file..."
    if docker compose -f "docker-compose-${file}.yml" down -v -t 1 --remove-orphans; then
        echo "✅ $file stopped successfully"
    else
        echo "❌ Failed to stop $file"
        return 1
    fi
}

echo "🛑 Stopping Blockscout..."
cd blockscout && docker compose down -v -t 1 --remove-orphans
rm -rf services/blockscout-db-data services/stats-db-data services/redis-data services/dets
cd ..

echo "🛑 Stopping all containers..."
for file in "${COMPOSE_FILES[@]}"; do
    if ! stop_container "$file"; then
        echo "Error: Failed to stop containers cleanly"
        exit 1
    fi
done

echo "🧹 Cleaning up images..."
docker rmi -f story-geth:localnet story-node:localnet 2>/dev/null || true

echo "🎉 All containers stopped and volumes removed successfully!"
