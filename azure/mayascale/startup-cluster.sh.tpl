#!/bin/bash

# MayaScale Composable Storage Startup Script - Azure
# This script sets up environment variables and calls MayaScale cluster setup

set -e

# Logging setup - use MayaScale logs directory only (no syslog)
umask 027  # Ensure log files are created with restrictive permissions
LOGFILE="/opt/mayastor/logs/mayascale-terraform-startup.log"
exec >> "$LOGFILE"
exec 2>&1

# Set proper ownership on log file
touch "$LOGFILE"
chmod 640 "$LOGFILE"
chown root:root "$LOGFILE"

echo "$(date): Starting MayaScale cluster configuration..."

# Variables from Terraform template
CLUSTER_NAME="${cluster_name}"
NODE_ROLE="${node_role}"
PERFORMANCE_POLICY="${performance_policy}"
AZURE_REGION="${location}"
RESOURCE_GROUP="${resource_group}"

# Client Volume Export Configuration
CLIENT_NVME_PORT="${client_nvme_port}"
CLIENT_ISCSI_PORT="${client_iscsi_port}"
CLIENT_PROTOCOL="${client_protocol}"
CLIENT_EXPORTS_ENABLED="${client_exports_enabled}"

echo "Cluster: $CLUSTER_NAME, Role: $NODE_ROLE"
echo "Performance Policy: $PERFORMANCE_POLICY"

# Check if already configured (run only on first boot)
if [ -f /opt/mayastor/config/.cluster-configured ]; then
    echo "$(date): MayaScale cluster already configured, skipping..."
    exit 0
fi

# Only run cluster setup on node1 (primary node)
if [ "$NODE_ROLE" != "node1" ]; then
    echo "$(date): Secondary node - cluster setup runs only on node1"
    exit 0
fi

# Get Azure instance metadata (zone and region for logging)
echo "$(date): Retrieving Azure instance metadata..."

ZONE=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/zone?api-version=2023-11-15&format=text" 2>/dev/null || echo "")
REGION=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/location?api-version=2023-11-15&format=text" 2>/dev/null || echo "unknown")

# Handle empty zone (many Azure regions don't have zones)
if [ "$ZONE" = "null" ]; then
    ZONE=""
fi

echo "Zone: $ZONE, Region: $REGION"

# Get instance information
INSTANCE_ID=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/vmId?api-version=2023-11-15&format=text" 2>/dev/null || echo "unknown")
INSTANCE_NAME=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/name?api-version=2023-11-15&format=text" 2>/dev/null || uname -n)
INTERNAL_IP=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2023-11-15&format=text" 2>/dev/null || echo "unknown")

echo "Instance: $INSTANCE_ID ($INSTANCE_NAME), Internal IP: $INTERNAL_IP"

# Node configuration from Terraform
PRIMARY_INSTANCE="${node1_name}"
SECONDARY_INSTANCE="${node2_name}"
PRIMARY_IP="$INTERNAL_IP"
PEER_IP="${secondary_private_ip}"
PRIMARY_BACKEND_IP="${backend_node1_ip}"
SECONDARY_BACKEND_IP="${backend_node2_ip}"

echo "Primary: $PRIMARY_INSTANCE ($PRIMARY_IP / backend: $PRIMARY_BACKEND_IP)"
if [ -n "$SECONDARY_INSTANCE" ]; then
    echo "Secondary: $SECONDARY_INSTANCE (backend: $SECONDARY_BACKEND_IP)"
fi

# Detect accelerated networking adapter and configure optimal MTU
echo "$(date): Checking for accelerated networking adapter..."

# Check for MANA (Microsoft Azure Network Adapter)
MANA=$(lspci -d 1414:00ba 2> /dev/null | wc -l)
if [ $MANA -gt 0 ] ; then
    TARGET_MTU=9000
    ADAPTER="MANA"
    echo "$(date): MANA adapter detected - configuring MTU $TARGET_MTU..."
# Check for Mellanox ConnectX
elif [ $(lspci -d 15b3: 2> /dev/null | wc -l) -gt 0 ]; then
    TARGET_MTU=3900
    ADAPTER="Mellanox ConnectX"
    echo "$(date): Mellanox adapter detected - configuring MTU $TARGET_MTU..."
else
    echo "$(date): No accelerated networking adapter detected - keeping default MTU 1500"
    TARGET_MTU=0
fi

# Configure MTU on hv_netvsc master interfaces
if [ "$TARGET_MTU" -gt 0 ]; then
    for iface in $(ip -o link show | awk -F': ' '{print $2}'); do
        # Skip loopback
        [ "$iface" = "lo" ] && continue

        driver=$(ethtool -i "$iface" 2>/dev/null | grep "^driver:" | awk '{print $2}')
        if [ "$driver" = "hv_netvsc" ]; then
            current_mtu=$(ip link show "$iface" | grep -oP 'mtu \K[0-9]+')
            if [ "$current_mtu" != "$TARGET_MTU" ]; then
                ip link set dev "$iface" mtu "$TARGET_MTU" 2>/dev/null && \
                    echo "$(date): Set MTU $TARGET_MTU on $iface (was $current_mtu)"
            else
                echo "$(date): $iface already has MTU $TARGET_MTU"
            fi
        fi
    done
fi

echo "Primary node calling MayaScale cluster setup..."

# Object cold tier (objbacker): fetch the storage account key BEFORE writing
# .startup-config, so the file below carries a plain value like every other export.
# This must NOT live inside the heredoc: it is unquoted, so a $(...) in there would run at
# WRITE time -- before az login -- and its empty output would be baked in permanently.
# On Azure the accessID IS the storage account name; the key is fetched with the VM's
# managed identity, so it never enters terraform or the state file.
STORAGE_ACCESS_KEY=""
if [ -n "${s3_access_key}" ]; then
    # The identity is not usable the moment the VM boots: az login must succeed before any
    # az call, and can take a couple of minutes to become available. Same 5x30s budget
    # mayanas uses.
    echo "$(date): Authenticating with managed identity for the object cold tier..."
    for i in {1..5}; do
        if az login --identity 2>/dev/null; then
            echo "$(date): Managed identity authentication successful"
            break
        fi
        echo "$(date): Managed identity auth attempt $i failed, retrying in 30s..."
        sleep 30
    done

    echo "$(date): Retrieving storage access key for the object cold tier..."
    for i in {1..5}; do
        STORAGE_ACCESS_KEY=$(az storage account keys list --resource-group "$RESOURCE_GROUP" --account-name "${s3_access_key}" --query "[0].value" -o tsv 2>/dev/null || echo "")
        if [ -n "$STORAGE_ACCESS_KEY" ]; then
            echo "$(date): Storage access key retrieved successfully"
            break
        fi
        echo "$(date): Storage access key retrieval attempt $i failed, retrying in 30s..."
        sleep 30
    done
    if [ -z "$STORAGE_ACCESS_KEY" ]; then
        echo "WARNING: could not retrieve the storage access key; the cold tier will be skipped"
    fi
fi

# Save deployment context before calling setup script (for recovery/debugging)
echo "$(date): Saving deployment context to /opt/mayastor/config/.startup-config..."
mkdir -p /opt/mayastor/config
cat > /opt/mayastor/config/.startup-config <<EOF
#!/bin/bash
# MayaScale Deployment Context - Auto-generated by Terraform startup script
# Source this file to restore deployment environment: source /opt/mayastor/config/.startup-config

# Required scalar variables
export MAYASCALE_CLUSTER_NAME="${cluster_name}"
export MAYASCALE_PRIMARY_INSTANCE="$PRIMARY_INSTANCE"
export MAYASCALE_SECONDARY_INSTANCE="$SECONDARY_INSTANCE"
export MAYASCALE_PRIMARY_IP="$PRIMARY_IP"
export MAYASCALE_SECONDARY_IP="$PEER_IP"
export MAYASCALE_BACKEND_PRIMARY_IP="$PRIMARY_BACKEND_IP"
export MAYASCALE_BACKEND_SECONDARY_IP="$SECONDARY_BACKEND_IP"
export MAYASCALE_CLOUD_PROVIDER="azure"

# Required array variables (space-separated). Single-node -> one id / one VIP, no peer
# (mirrors azure/mayanas). MAYASCALE_DEPLOYMENT_TYPE=*-single is the single-node signal;
# SECONDARY_INSTANCE / PEER_IP / SECONDARY_BACKEND_IP are already empty for single-node.
%{ if node_count > 1 ~}
export MAYASCALE_RESOURCE_ID="${resource_id} ${peer_resource_id}"
export MAYASCALE_VIP_ADDRESS="${vip_address} ${vip_address_2}"
%{ else ~}
export MAYASCALE_RESOURCE_ID="0"
export MAYASCALE_VIP_ADDRESS="${vip_address}"
%{ endif ~}

# Additional configuration variables
export MAYASCALE_HA_DATA="${ha_data}"
export MAYASCALE_NODE_ROLE="${node_role}"
export MAYASCALE_DEPLOYMENT_TYPE="${deployment_type}"
export MAYASCALE_ZONE="$ZONE"
export MAYASCALE_REGION="$REGION"
export MAYASCALE_INSTANCE_NAME="$INSTANCE_NAME"
export MAYASCALE_RESOURCE_GROUP="${resource_group}"
export MAYASCALE_PROJECT_ID="${resource_group}"  # Azure equivalent of GCP PROJECT_ID - required by failover.pl
export MAYASCALE_PERFORMANCE_POLICY="${performance_policy}"

# Object cold tier (objbacker): the buckets tenant datasets are replicated onto
# from the local-NVMe hot pool. Empty unless terraform ran with bucket_count > 0.
# On Azure the accessID IS the storage account name; the secret is fetched here
# with the VM's managed identity so it never lands in terraform state.
export MAYASCALE_S3_ACCESS_KEY="${s3_access_key}"
export MAYASCALE_S3_SECRET_KEY="$STORAGE_ACCESS_KEY"
export MAYASCALE_COLD_BUCKETS_NODE1="${bucket_node1}"
export MAYASCALE_COLD_BUCKETS_NODE2="${bucket_node2}"
export MAYASCALE_NVME_COUNT="${nvme_count}"
%{ if node_count > 1 ~}
export MAYASCALE_CLUSTER_ID="${resource_id}"
%{ else ~}
export MAYASCALE_CLUSTER_ID="0"
%{ endif ~}
%{ if mayascale_startup_wait != "" ~}
export MAYASCALE_STARTUP_WAIT="${mayascale_startup_wait}"
%{ endif ~}

# Client volume export configuration
export CLIENT_NVME_PORT="${client_nvme_port}"
export CLIENT_ISCSI_PORT="${client_iscsi_port}"
export CLIENT_PROTOCOL="${client_protocol}"
export CLIENT_EXPORTS_ENABLED="${client_exports_enabled}"

# NFS/SMB shares configuration (JSON-encoded)
export MAYASCALE_SHARES_CONFIG='${shares}'

# If empty or empty array, use default share1 with wildcard access
if [ -z "\$MAYASCALE_SHARES_CONFIG" ] || [ "\$MAYASCALE_SHARES_CONFIG" = "[]" ]; then
  export MAYASCALE_SHARES_CONFIG='[{"name":"share1","recordsize":"128K","export":"nfs","nfs_options":"*(rw,sync,no_subtree_check,no_root_squash)","smb_options":""}]'
fi

export MAYASCALE_TERRAFORM_SAVED_AT="$(date -Iseconds)"

echo "Deployment context loaded: \$MAYASCALE_CLUSTER_NAME - Node: \$MAYASCALE_NODE_ROLE"
EOF

chmod +x /opt/mayastor/config/.startup-config
chown root:root /opt/mayastor/config/.startup-config
echo "$(date): Deployment context saved - source /opt/mayastor/config/.startup-config to restore"

# Source the deployment context to load environment variables
echo "$(date): Loading deployment context for cluster setup..."
source /opt/mayastor/config/.startup-config

# Setup script: cluster_mayascale.sh for 2-node active-active; standalone_mayascale.sh for
# single-node (no peer/mirror/replication). Mirrors azure/mayanas (standalone_setup.sh vs cluster_setup*).
%{ if node_count > 1 ~}
MAYASCALE_SETUP_SCRIPT="/opt/mayastor/config/cluster_mayascale.sh"
%{ else ~}
MAYASCALE_SETUP_SCRIPT="/opt/mayastor/config/standalone_mayascale.sh"
%{ endif ~}

if [ ! -f "$MAYASCALE_SETUP_SCRIPT" ]; then
    echo "$(date): WARNING: MayaScale setup script not found at $MAYASCALE_SETUP_SCRIPT"
    echo "$(date): This VM image may not have MayaScale pre-installed"
    echo "$(date): Deployment context saved - cluster setup can be run manually"
    exit 0
fi

echo "$(date): Launching MayaScale cluster setup in background..."
nohup $MAYASCALE_SETUP_SCRIPT > /opt/mayastor/logs/cluster-setup-background.log 2>&1 &
SETUP_PID=$!

echo "$(date): MayaScale cluster setup launched with PID $SETUP_PID"
echo "$(date): Monitor progress with: tail -f /opt/mayastor/logs/cluster-setup-background.log"
echo "$(date): Terraform startup script completed - returning to Azure metadata agent"

# The cluster_mayascale.sh script will:
# 1. Wait for essential services to be ready
# 2. Perform cluster initialization
# 3. Create /opt/mayastor/config/.cluster-configured when done
