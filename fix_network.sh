#!/bin/bash
# Fix Docker network conflict by cleaning up old networks

set -e

echo "🔧 Fixing Docker network conflict..."
echo ""

# Stop containers using the old network
echo "1. Stopping containers using old network..."
docker ps --filter "network=story-localnet-alpha_story-localnet" --format "{{.Names}}" | while read container; do
    if [ -n "$container" ]; then
        echo "   Stopping $container..."
        docker stop "$container" 2>/dev/null || true
    fi
done

# Remove old network
echo ""
echo "2. Removing old network..."
docker network rm story-localnet-alpha_story-localnet 2>&1 || {
    echo "   ⚠️  Could not remove network (may already be removed or still in use)"
}

# List remaining networks
echo ""
echo "3. Checking for other conflicting networks..."
CONFLICTING_NETWORKS=$(docker network ls --format "{{.Name}}" | grep -E "story.*localnet" || true)
if [ -n "$CONFLICTING_NETWORKS" ]; then
    echo "   Found networks:"
    echo "$CONFLICTING_NETWORKS" | sed 's/^/     - /'
    echo ""
    echo "   You may need to manually remove these if they conflict:"
    echo "   docker network rm <network_name>"
else
    echo "   ✓ No conflicting networks found"
fi

echo ""
echo "✅ Network cleanup completed!"
echo ""
echo "Now you can run ./start.sh again"

