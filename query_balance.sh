#!/bin/bash

# Check if an address is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <eth-address>"
    exit 1
fi

# Assign the address to a variable
address="$1"

# Infinite loop to continuously query
while true; do
    # Fetch the latest block height
    height_hex=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        http://localhost:8545 | jq -r '.result')

    # Check if height is valid and remove 0x prefix
    if [[ $height_hex == 0x* ]]; then
        height_decimal=$((16#${height_hex#0x}))
    else
        echo "Invalid block height: $height_hex"
        exit 1
    fi

    # Fetch the balance of the given address
    balance_hex=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_getBalance","params":["'"$address"'", "latest"],"id":1}' \
        http://localhost:8545 | jq -r '.result')

    # Check if balance_hex is valid
    if [[ -z "$balance_hex" || $balance_hex == "null" ]]; then
        echo "Error: Failed to fetch balance. Raw Balance: $balance_hex"
        exit 1
    fi

    # Debug: Print raw balance
    echo "Raw Balance (hex): $balance_hex"

    # Convert hex balance to decimal using python3
    balance_wei=$(python3 -c "print(int('${balance_hex#0x}', 16))")
    if [[ -z "$balance_wei" ]]; then
        echo "Error: Failed to convert balance to Wei. Raw Balance: $balance_hex"
        exit 1
    fi

    # Debug: Print balance in Wei
    echo "Balance in Wei: $balance_wei"

    # Convert balance from Wei to Ether using Python
    ether_balance=$(python3 -c "print(${balance_wei} / 10**18)")

    # Print the height and balance
    echo "Block Height: $height_decimal, Address: $address, Balance: $ether_balance ETH"

    # Wait for 3 seconds before the next query
    sleep 3
done