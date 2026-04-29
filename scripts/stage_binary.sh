#!/usr/bin/env bash
# stage_binary.sh — Stage a freshly-built story linux binary at the path
# the docker-compose build context expects, and record a sha256 fingerprint
# so start.sh can verify the running image actually contains this binary.
#
# Usage:
#   ./scripts/stage_binary.sh <path-to-linux-arm64-or-amd64-story-binary>
#
# Example:
#   ./scripts/stage_binary.sh ../story-private-fork/build/story-linux
#   ./scripts/stage_binary.sh ../story/build/story-linux
#
# Why this exists:
#   The docker-compose-*.yml `build.context` points to a sibling repo
#   (e.g., ../story-private-fork). `Dockerfile.story-node` then runs
#   `COPY story-prebuilt /usr/local/bin/story` — relative to the build
#   context, NOT relative to story-localnet. Manually `cp`-ing to
#   story-localnet/story-prebuilt is silently ignored by docker. This
#   script derives the destination from docker-compose so it adapts to
#   whichever sibling repo the context currently points to.

set -euo pipefail

SRC=${1:?usage: stage_binary.sh <path-to-linux-story-binary>}

if [[ ! -f "$SRC" ]]; then
    echo "ERROR: source binary not found at $SRC" >&2
    exit 1
fi

LOCALNET_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$LOCALNET_DIR/docker-compose-bootnode1.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "ERROR: $COMPOSE_FILE not found — are you in story-localnet?" >&2
    exit 1
fi

# Extract bootnode1-node service's build.context. AWK over the YAML treats
# every top-level service block as a window; print the first `context:`
# value inside the `bootnode1-node:` window.
CTX=$(awk '
    /^  bootnode1-node:/ { in_block=1; next }
    in_block && /^  [a-zA-Z]/ { in_block=0 }
    in_block && $1 == "context:" { print $2; exit }
' "$COMPOSE_FILE")

if [[ -z "$CTX" ]]; then
    echo "ERROR: could not derive build.context from $COMPOSE_FILE" >&2
    exit 1
fi

DEST="$LOCALNET_DIR/$CTX/story-prebuilt"
SENTINEL="$LOCALNET_DIR/tmp/staged_binary.sha256"

mkdir -p "$LOCALNET_DIR/tmp"
cp -v "$SRC" "$DEST"

HASH=$(shasum -a 256 "$DEST" | awk '{print $1}')
BUILDID=$(file "$DEST" | grep -oE 'BuildID\[sha1\]=[a-f0-9]+' || echo 'BuildID[sha1]=<unknown>')

echo "$HASH" > "$SENTINEL"

echo "---"
echo "Staged binary: $DEST"
echo "  sha256:   $HASH"
echo "  $BUILDID"
echo "  sentinel: $SENTINEL  (start.sh will compare image binary against this)"
