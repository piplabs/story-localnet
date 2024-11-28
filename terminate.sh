#!/bin/bash

COMPOSE_FILES=(
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
    if docker compose -f "docker-compose-${file}.yml" down -v -t 1; then
        echo "✅ $file stopped successfully"
    else
        echo "❌ Failed to stop $file"
        return 1
    fi
}

echo "🛑 Stopping all containers..."
for file in "${COMPOSE_FILES[@]}"; do
    if ! stop_container "$file"; then
        echo "Error: Failed to stop containers cleanly"
        exit 1
    fi
done

echo "🎉 All containers stopped and volumes removed successfully!"
