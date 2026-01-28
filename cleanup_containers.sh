#!/bin/bash
# Clean up conflicting containers before starting

set -e

echo "🧹 Cleaning up conflicting containers..."

# Stop and remove monitoring containers
MONITORING_CONTAINERS=("loki" "prometheus" "promtail" "grafana")

for container in "${MONITORING_CONTAINERS[@]}"; do
    if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
        echo "  Stopping $container..."
        docker stop "$container" 2>/dev/null || true
        echo "  Removing $container..."
        docker rm "$container" 2>/dev/null || true
    fi
done

echo "✅ Cleanup completed!"

