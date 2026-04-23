#!/bin/bash
# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.


# MayaScale Volume Connection Script
# Connects client to MayaScale storage volumes via NVMe-oF (TCP or RDMA)

set -e

# Install required packages if missing
install_nvme_packages() {
    echo "Checking NVMe-oF client prerequisites..."

    # Check for nvme-cli
    if ! command -v nvme &>/dev/null; then
        echo "Installing nvme-cli..."
        sudo apt-get update -qq >/dev/null
        sudo apt-get install -qq -y nvme-cli jq >/dev/null
    fi

    # Check for nvme-tcp kernel module
    if ! lsmod | grep -q nvme_tcp; then
        echo "Loading nvme-tcp kernel module..."
        if ! sudo modprobe nvme-tcp 2>/dev/null; then
            echo "Installing linux-modules-extra for nvme-tcp support..."
            sudo apt-get update -qq >/dev/null
            sudo apt-get install -qq -y linux-modules-extra-$(uname -r) >/dev/null
            sudo modprobe nvme-tcp
        fi
    fi

    echo "NVMe-oF client ready"
}

install_nvme_packages

# Parse arguments
TRANSPORT="${1:-tcp}"  # Default to tcp, can be "rdma"

# Validate transport
if [[ "$TRANSPORT" != "tcp" && "$TRANSPORT" != "rdma" ]]; then
    echo "Error: Invalid transport '$TRANSPORT'. Must be 'tcp' or 'rdma'"
    exit 1
fi

# Verify RDMA capability if transport is rdma
if [ "$TRANSPORT" = "rdma" ]; then
    RDMA_DEVICES=$(ls /sys/class/infiniband 2>/dev/null | wc -l)
    if [ "$RDMA_DEVICES" -eq 0 ]; then
        echo "Error: No RDMA devices found in /sys/class/infiniband. Falling back to TCP."
        TRANSPORT="tcp"
    else
        echo "RDMA devices found ($RDMA_DEVICES): $(ls /sys/class/infiniband)"
    fi
fi

echo "Connecting to MayaScale volumes (transport: $TRANSPORT)..."

CONFIG_FILE="$HOME/storage_config.json"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Parse VIPs and volumes from JSON
PRIMARY_VIP=$(jq -r ".primary_vip" "$CONFIG_FILE")
SECONDARY_VIP=$(jq -r ".secondary_vip" "$CONFIG_FILE")

echo "Primary VIP: $PRIMARY_VIP"
echo "Secondary VIP: $SECONDARY_VIP"

# Connect to each volume
jq -r ".volumes | to_entries[] | \"\(.key) \(.value.nqn) \(.value.vip_address) \(.value.port)\"" "$CONFIG_FILE" | while read volume_name nqn vip_address port; do
    echo ""
    echo "Connecting to $volume_name (NQN: $nqn, VIP: $vip_address, Port: $port)"

    # Discover
    if sudo nvme discover -t "$TRANSPORT" -a "$vip_address" -s "$port" 2>/dev/null; then
        echo "  ✓ Discovery successful for $volume_name"
    else
        echo "  ✗ Discovery failed for $volume_name"
        continue
    fi

    # Connect
    if sudo nvme connect -t "$TRANSPORT" -a "$vip_address" -s "$port" -n "$nqn" 2>/dev/null; then
        echo "  ✓ Connection successful for $volume_name"
    else
        echo "  ✗ Connection failed for $volume_name (may already be connected)"
    fi
done

echo ""
echo "Connection attempts complete. Checking connected devices:"
echo ""
sudo nvme list
echo ""
sudo lsblk
