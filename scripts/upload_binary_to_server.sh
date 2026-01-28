#!/usr/bin/env bash
set -euo pipefail

# Script to upload story binary to remote Ubuntu server via gcloud
# Usage: ./scripts/upload_binary_to_server.sh [local_binary_path] [remote_path]
#
# If binary path is not provided, it will look for:
#   1. ../story/story (relative to story-localnet)
#   2. ./story (in story-localnet directory)
#   3. story (in PATH)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCALNET_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# GCloud connection parameters
ZONE="us-east1-d"
INSTANCE="yao-testnode-aeneid-20251224-20260115-064959"
PROJECT="story-aeneid"
USER="ubuntu"
REMOTE_DEFAULT_PATH="~/story"

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
  echo "  $0 <path_to_story_binary> [remote_path]" >&2
  exit 1
fi

# Check if source binary exists
if [[ ! -f "$SOURCE_BINARY" ]]; then
  echo "Error: Binary file not found: $SOURCE_BINARY" >&2
  exit 1
fi

# Determine remote destination path
if [[ $# -ge 2 ]]; then
  REMOTE_PATH="$2"
else
  REMOTE_PATH="$REMOTE_DEFAULT_PATH"
fi

echo "Uploading binary to server..."
echo "  Source: $SOURCE_BINARY"
echo "  Destination: $USER@$INSTANCE:$REMOTE_PATH"
echo "  Zone: $ZONE"
echo "  Project: $PROJECT"
echo ""

# Upload using gcloud compute scp
gcloud compute scp \
  --zone "$ZONE" \
  --project "$PROJECT" \
  --tunnel-through-iap \
  --ssh-key-expire-after=1h \
  "$SOURCE_BINARY" \
  "$USER@$INSTANCE:$REMOTE_PATH"

echo ""
echo "Upload completed successfully!"
echo "Binary is now available at: $REMOTE_PATH on $INSTANCE"

