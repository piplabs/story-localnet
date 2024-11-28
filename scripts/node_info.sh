#!/bin/bash

# List of container names
containers=(
  "bootnode1" 
  "validator1" 
  "validator2" 
  "validator3" 
  "validator4"
)

# Header for output
echo "==================== Peer Information ===================="

# Loop over each container and retrieve peer information
for container in "${containers[@]}"; do
  echo "Container: $container"
  echo "---------------------------------------------------------"

  # Ensure dependencies are installed inside the container
  docker exec -i "$container-node" apk add curl jq > /dev/null 2>&1

  # Retrieve enode information (Geth)
  enode=$(docker exec -i "$container-geth" geth --exec 'admin.nodeInfo.enode;' attach http://localhost:8545 2>/dev/null | tr -d '\r\n"')
  if [[ -n $enode ]]; then
    echo "Enode: $enode"
  else
    echo "Enode: Not available"
  fi

  # Retrieve Node ID (Cosmos SDK)
  node_id=$(docker exec -i "$container-node" curl -s http://localhost:26657/status | jq -r '.result.node_info.id' 2>/dev/null | tr -d '\r\n')
  if [[ -n $node_id ]]; then
    echo "Node ID: $node_id"
  else
    echo "Node ID: Not available"
  fi

  # Retrieve Validator and Delegator Addresses
  validator_export=$(docker exec -i "$container-node" story validator export 2>/dev/null)
  if [[ -n $validator_export ]]; then
    echo "$validator_export" | grep -E "Validator Address|Delegator Address|Compressed Public Key"
  else
    echo "Validator/Delegator Address: Not available"
  fi

  echo "========================================================="
done
