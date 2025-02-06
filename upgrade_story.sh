#!/bin/bash

# Define the validator nodes
validators=("validator1-node" "validator2-node" "validator3-node" "validator4-node")

# Define the source file path
source_path="../story/story"
echo "====== source_path $source_path ======"

# Iterate over each validator node
for validator in "${validators[@]}"; do
    echo "Processing $validator..."

    # Stop the container
    echo "Stopping $validator..."
    docker stop "$validator"

    # Copy the updated story binary
    echo "Copying story binary to $validator..."
    docker cp "$source_path" "$validator:/usr/local/bin/story"

    # Start the container
    echo "Starting $validator..."
    docker start "$validator"

    # Wait for 10 seconds before processing the next validator
    echo "Waiting for 10 seconds..."
    sleep 10
done

echo "All validators updated successfully!"