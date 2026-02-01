#!/bin/bash

# MayaScale Composable Storage Startup Script
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
VIP_ADDRESS="${vip_address}"
PERFORMANCE_POLICY="${performance_policy}"
PEER_ZONE="${peer_zone}"

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

# Only run cluster setup on node1 (primary node in active-active)
if [ "$NODE_ROLE" != "node1" ]; then
    echo "$(date): Secondary node - cluster setup runs only on node1"
    exit 0
fi

# Get zone first (needed for region calculation)
ZONE=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/zone | cut -d'/' -f4)

# Ensure subnet has secondary IP range for alias IPs
echo "$(date): Checking subnet secondary IP range for alias IPs..."
REGION=$(echo "$ZONE" | sed 's/-[^-]*$//')

# Get network/subnet name from instance metadata
NETWORK_PATH=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/network)
SUBNET_NAME=$(basename "$NETWORK_PATH")

echo "$(date): Using subnet: $SUBNET_NAME in region: $REGION"

# Ensure mayascale-alias-range secondary range exists for VIP
VIP_CIDR_RANGE="${vip_cidr_range}"
echo "$(date): Ensuring secondary IP range exists for VIP: $VIP_CIDR_RANGE"

# Check if mayanas-alias-range already exists (shared with MayaNAS)
EXISTING_RANGE=$(gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --format="value(secondaryIpRanges[].rangeName,secondaryIpRanges[].ipCidrRange)" | grep "mayanas-alias-range" | cut -f2 -d$'\t')

if [ -n "$EXISTING_RANGE" ]; then
    echo "$(date): Secondary range 'mayanas-alias-range' already exists with CIDR: $EXISTING_RANGE"
    if [ "$EXISTING_RANGE" != "$VIP_CIDR_RANGE" ]; then
        echo "WARNING: Existing range $EXISTING_RANGE differs from expected $VIP_CIDR_RANGE"
    fi
elif ! gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --format="value(secondaryIpRanges[].ipCidrRange)" | grep -q "$VIP_CIDR_RANGE"; then
    echo "$(date): Creating secondary IP range: mayanas-alias-range=$VIP_CIDR_RANGE"
    if gcloud compute networks subnets update "$SUBNET_NAME" \
        --region="$REGION" \
        --add-secondary-ranges=mayanas-alias-range="$VIP_CIDR_RANGE" \
        --quiet; then
        echo "$(date): Successfully created secondary IP range"
    else
        echo "ERROR: Failed to create secondary IP range - cluster setup cannot proceed"
        exit 1
    fi
else
    echo "$(date): CIDR range $VIP_CIDR_RANGE already exists, using mayanas-alias-range reference"
    # Find existing range name that matches our CIDR
    EXISTING_RANGE_NAME=$(gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --format="value(secondaryIpRanges[].rangeName,secondaryIpRanges[].ipCidrRange)" | grep "$VIP_CIDR_RANGE" | cut -f1 -d$'\t')
    echo "$(date): Found existing range '$EXISTING_RANGE_NAME' with matching CIDR $VIP_CIDR_RANGE"
fi

# Check if VIP alias is already configured on this instance
echo "$(date): Checking if VIP alias IP is already configured..."
EXISTING_ALIASES=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip-aliases/)

if echo "$EXISTING_ALIASES" | grep -q "$VIP_ADDRESS"; then
    echo "$(date): VIP alias IP $VIP_ADDRESS is already configured"
else
    echo "$(date): VIP alias IP $VIP_ADDRESS not found in current aliases"
    echo "$(date): Current aliases: $EXISTING_ALIASES"
fi

# Ensure MayaScale setup script exists
MAYASCALE_SETUP_SCRIPT="/opt/mayastor/config/cluster_mayascale.sh"
if [ ! -x "$MAYASCALE_SETUP_SCRIPT" ]; then
    echo "ERROR: MayaScale setup script not found at $MAYASCALE_SETUP_SCRIPT"
    exit 1
fi

# Get remaining instance metadata
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/name)
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/project/project-id)
INTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

# Get backend network IP (second NIC)
BACKEND_IP=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/1/ip)

# Configure MTU 8896 on all network interfaces (required for Tier_1 networking)
echo "$(date): Configuring MTU 8896 on all network interfaces..."
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
    current_mtu=$(ip link show "$iface" | grep -oP 'mtu \K[0-9]+')
    if [ "$current_mtu" != "8896" ]; then
        if ip link set dev "$iface" mtu 8896 2>/dev/null; then
            echo "$(date): Set MTU 8896 on $iface (was $current_mtu)"
        else
            echo "$(date): WARNING: Could not set MTU 8896 on $iface"
        fi
    else
        echo "$(date): $iface already has MTU 8896"
    fi
done

# Instance names from terraform template (following MayaNAS pattern)
PRIMARY_INSTANCE="${primary_instance}"
SECONDARY_INSTANCE="${secondary_instance}"

# Get peer IPs (secondary node IPs from primary's perspective)
PEER_IP=$(gcloud compute instances describe "$SECONDARY_INSTANCE" \
    --zone="${peer_zone}" \
    --project="$PROJECT_ID" \
    --format="value(networkInterfaces[0].networkIP)" 2>/dev/null || echo "")

PEER_BACKEND_IP=$(gcloud compute instances describe "$SECONDARY_INSTANCE" \
    --zone="${peer_zone}" \
    --project="$PROJECT_ID" \
    --format="value(networkInterfaces[1].networkIP)" 2>/dev/null || echo "")

echo "Primary node calling MayaScale cluster setup..."

# Save deployment context before calling setup script (for recovery/debugging)
echo "$(date): Saving deployment context to /opt/mayastor/config/.startup-config..."
mkdir -p /opt/mayastor/config
cat > /opt/mayastor/config/.startup-config <<EOF
#!/bin/bash
# MayaScale Deployment Context - Auto-generated by Terraform startup script
# Source this file to restore deployment environment: source /opt/mayastor/config/.startup-config

# Cluster configuration
export MAYASCALE_CLUSTER_NAME="${cluster_name}"
export MAYASCALE_NODE_ROLE="${node_role}"
export MAYASCALE_DEPLOYMENT_TYPE="${deployment_type}"
export MAYASCALE_CLOUD_PROVIDER="gcp"
export MAYASCALE_ZONE="$ZONE"
export MAYASCALE_REGION="$REGION"
export MAYASCALE_PEER_ZONE="${peer_zone}"
%{ if mayascale_startup_wait != "" ~}
export MAYASCALE_STARTUP_WAIT="${mayascale_startup_wait}"
%{ endif ~}

# Instance configuration
export MAYASCALE_PRIMARY_INSTANCE="$PRIMARY_INSTANCE"
export MAYASCALE_SECONDARY_INSTANCE="$SECONDARY_INSTANCE"
export MAYASCALE_INSTANCE_NAME="$INSTANCE_NAME"

# Network configuration (space-separated pairs for active-active)
export MAYASCALE_VIP_ADDRESS="${vip_address} ${vip_address_2}"
export MAYASCALE_VIP_CIDR_RANGE="$VIP_CIDR_RANGE"
export MAYASCALE_PRIMARY_IP="$INTERNAL_IP"
export MAYASCALE_SECONDARY_IP="$PEER_IP"
export MAYASCALE_BACKEND_PRIMARY_IP="$BACKEND_IP"
export MAYASCALE_BACKEND_SECONDARY_IP="$PEER_BACKEND_IP"

# System configuration (space-separated pairs for active-active)
export MAYASCALE_PROJECT_ID="$PROJECT_ID"
export MAYASCALE_RESOURCE_ID="${resource_id} ${peer_resource_id}"
export MAYASCALE_PERFORMANCE_POLICY="${performance_policy}"
export MAYASCALE_NVME_COUNT="${nvme_count}"
export MAYASCALE_CLUSTER_ID="${resource_id}"

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

# Deployment metadata
export MAYASCALE_TERRAFORM_SAVED_AT="$(date -Iseconds)"

echo "Deployment context loaded: \$MAYASCALE_CLUSTER_NAME - Node: \$MAYASCALE_NODE_ROLE"
EOF

chmod +x /opt/mayastor/config/.startup-config
chown root:root /opt/mayastor/config/.startup-config
echo "$(date): Deployment context saved - source /opt/mayastor/config/.startup-config to restore"

# Source the deployment context to load environment variables
echo "$(date): Loading deployment context for cluster setup..."
source /opt/mayastor/config/.startup-config

# Call MayaScale setup script (MayaScale uses cluster_mayascale.sh for active-active composable storage)
echo "$(date): Launching MayaScale cluster setup in background..."
nohup $MAYASCALE_SETUP_SCRIPT > /opt/mayastor/logs/cluster-setup-background.log 2>&1 &
SETUP_PID=$!

echo "$(date): MayaScale cluster setup launched with PID $SETUP_PID"
echo "$(date): Monitor progress with: tail -f /opt/mayastor/logs/cluster-setup-background.log"
echo "$(date): Terraform startup script completed - returning to Google metadata agent"

# The mayascale_cluster_setup.sh script will:
# 1. Wait for essential services to be ready
# 2. Perform cluster initialization
# 3. Create /opt/mayastor/config/.cluster-configured when done
# 4. Remove startup-script metadata to prevent re-runs
