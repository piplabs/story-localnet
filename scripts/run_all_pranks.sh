#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

SCRIPTS=(
  "prank_delegator_rewards_shares.sh"
  "prank_new_delegator_stake_v142.sh"
  "prank_new_delegator_stake_v143.sh"
  "prank_new_delegator_stake.sh"
  "prank_rewards_genesis.sh"
  "prank_share_v143.sh"
)

echo "Running prank scripts sequentially..."
echo "Scripts directory: ${SCRIPT_DIR}"
echo ""

for script in "${SCRIPTS[@]}"; do
  script_path="${SCRIPT_DIR}/${script}"
  if [[ ! -f "$script_path" ]]; then
    echo "Missing script: ${script_path}" >&2
    exit 1
  fi

  echo "===================================================="
  echo "Starting: ${script}"
  echo "===================================================="
  bash "$script_path"
  echo "Finished: ${script}"
  echo ""
done

echo "All prank scripts completed."
