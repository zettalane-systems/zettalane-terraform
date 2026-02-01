#!/bin/bash

# MayaScale Composable Storage Startup Script for AWS
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

echo "$(date): Starting MayaScale cluster configuration for AWS..."

# Check and install AWS CLI if needed
if ! command -v aws >/dev/null 2>&1; then
    echo "$(date): AWS CLI not found, installing..."
    dnf install -y awscli
    echo "$(date): AWS CLI installed successfully"
else
    echo "$(date): AWS CLI already available"
fi

# Variables from Terraform template
CLUSTER_NAME="${cluster_name}"
NODE_ROLE="${node_role}"
VIP_ADDRESS="${vip_address}"
VIP_ADDRESS_2="${vip_address_2}"
PERFORMANCE_POLICY="${performance_policy}"

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

# Get zone and region information from AWS metadata
ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
PEER_ZONE="${peer_zone}"

echo "Zone: $ZONE, Peer Zone: $PEER_ZONE, Region: $REGION"

# Get instance information from AWS metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_NAME=$(uname -n)
INTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
EXTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")

echo "Instance: $INSTANCE_ID ($INSTANCE_NAME), IP: $INTERNAL_IP"

# Backend network IP (passed from Terraform - matches CloudFormation approach)
# No metadata query needed - backend IPs are static and known at deployment time
BACKEND_IP="${primary_backend_ip}"
echo "$(date): Backend IP (from Terraform): $BACKEND_IP"

# Peer information passed from Terraform template (matches CloudFormation approach)
PEER_IP="${secondary_private_ip}"
PEER_BACKEND_IP="${secondary_backend_ip}"
PEER_INSTANCE_ID="${secondary_instance_id}"
PEER_HOSTNAME="${secondary_hostname}"

echo "$(date): Secondary instance IP: $PEER_IP"
echo "$(date): Secondary instance backend IP: $PEER_BACKEND_IP"
echo "$(date): Secondary instance ID: $PEER_INSTANCE_ID"
echo "$(date): Secondary hostname: $PEER_HOSTNAME"

# Use hostname from Terraform (CloudFormation pattern)
# Fallback to reverse DNS if hostname not provided
if [ -n "$PEER_HOSTNAME" ] && [ "$PEER_HOSTNAME" != "" ]; then
    SECONDARY_INSTANCE="$PEER_HOSTNAME"
    echo "$(date): Using secondary hostname from Terraform: $SECONDARY_INSTANCE"
elif [ -n "$PEER_IP" ]; then
    SECONDARY_INSTANCE=$(host "$PEER_IP" | awk '{print $NF}' | sed 's/\.$//')
    if [ -z "$SECONDARY_INSTANCE" ] || [ "$SECONDARY_INSTANCE" = "not" ]; then
        echo "$(date): Could not resolve hostname for IP $PEER_IP, using IP"
        SECONDARY_INSTANCE="$PEER_IP"
    else
        echo "$(date): Resolved secondary hostname via DNS: $SECONDARY_INSTANCE"
    fi
else
    echo "WARNING: Secondary IP not provided"
    SECONDARY_INSTANCE=""
fi

PRIMARY_INSTANCE="$INSTANCE_NAME"
PRIMARY_INSTANCE_ID="$INSTANCE_ID"
SECONDARY_INSTANCE_ID="$PEER_INSTANCE_ID"

# Configure MTU 9001 on all network interfaces (AWS VPC maximum for jumbo frames)
# Required for optimal replication performance on backend network
echo "$(date): Configuring MTU 9001 (jumbo frames) on all network interfaces..."
for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^eth[0-9]+$'); do
    current_mtu=$(ip link show "$iface" | grep -oP 'mtu \K[0-9]+')
    if [ "$current_mtu" != "9001" ]; then
        if ip link set dev "$iface" mtu 9001 2>/dev/null; then
            echo "$(date): Set MTU 9001 on $iface (was $current_mtu)"
        else
            echo "$(date): WARNING: Could not set MTU 9001 on $iface (may already be at maximum)"
        fi
    else
        echo "$(date): $iface already has MTU 9001"
    fi
done

# Configure backend network routing for cross-AZ deployments
# Cross-AZ requires Layer 3 routing via VPC gateway (no Layer 2/ARP between AZs)
%{ if is_cross_az }
echo "$(date): Cross-AZ deployment detected - adding route to peer subnet via gateway..."
BACKEND_IFACE="eth1"

# Wait for eth1 to be attached and up with DHCP configuration
for i in {1..30}; do
    if ip addr show dev "$BACKEND_IFACE" 2>/dev/null | grep -q "inet.*\/25"; then
        echo "$(date): Backend interface $BACKEND_IFACE is configured and ready"
        break
    fi
    echo "$(date): Waiting for backend interface $BACKEND_IFACE DHCP configuration... ($i/30)"
    sleep 2
done

# Add route to peer's /25 subnet via VPC gateway
# Node1 (10.200.0.0/25) needs route to 10.200.0.128/25 via 10.200.0.1
# VPC router at .1 knows about both subnets and forwards packets cross-AZ
GATEWAY_IP="10.200.0.1"
PEER_SUBNET="10.200.0.128/25"

echo "$(date): Adding route to $PEER_SUBNET via $GATEWAY_IP..."
if ! ip route show | grep -q "$PEER_SUBNET"; then
    ip route add $PEER_SUBNET via $GATEWAY_IP dev $BACKEND_IFACE
    echo "$(date): Route added: $PEER_SUBNET via $GATEWAY_IP dev $BACKEND_IFACE"
else
    echo "$(date): Route to $PEER_SUBNET already exists"
fi

# Verify routing
echo "$(date): Backend routing table:"
ip route show | grep "10.200.0"
%{ else }
echo "$(date): Same-AZ deployment - using default DHCP network configuration"
%{ endif }

# VIPs are NOT pre-assigned (matches MayaNAS pattern and CloudFormation)
# Pacemaker's awsIP resource agent will dynamically assign/unassign VIPs via AWS API
# Pre-assigning causes conflict: awsIP tries to bind VIP but it already exists on interface
echo "$(date): VIPs will be managed dynamically by Pacemaker (not pre-assigned)"
echo "$(date): VIP addresses: $VIP_ADDRESS, $VIP_ADDRESS_2"

echo "Primary node calling MayaScale cluster setup..."

# Ensure MayaScale setup script exists
MAYASCALE_SETUP_SCRIPT="/opt/mayastor/config/cluster_mayascale.sh"
if [ ! -x "$MAYASCALE_SETUP_SCRIPT" ]; then
    echo "ERROR: MayaScale setup script not found at $MAYASCALE_SETUP_SCRIPT"
    exit 1
fi

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
export MAYASCALE_CLOUD_PROVIDER="aws"
export MAYASCALE_ZONE="$ZONE"
export MAYASCALE_REGION="$REGION"
export MAYASCALE_PEER_ZONE="${peer_zone}"
%{ if mayascale_startup_wait != "" ~}
export MAYASCALE_STARTUP_WAIT="${mayascale_startup_wait}"
%{ endif ~}

# Instance configuration
export MAYASCALE_PRIMARY_INSTANCE="$PRIMARY_INSTANCE"
export MAYASCALE_SECONDARY_INSTANCE="$SECONDARY_INSTANCE"
export MAYASCALE_PRIMARY_INSTANCE_ID="$PRIMARY_INSTANCE_ID"
export MAYASCALE_SECONDARY_INSTANCE_ID="$SECONDARY_INSTANCE_ID"
export MAYASCALE_INSTANCE_NAME="$INSTANCE_NAME"
export MAYASCALE_INSTANCE_ID="$INSTANCE_ID"

# Network configuration (space-separated pairs for active-active)
export MAYASCALE_VIP_ADDRESS="${vip_address} ${vip_address_2}"
export MAYASCALE_PRIMARY_IP="$INTERNAL_IP"
export MAYASCALE_SECONDARY_IP="$PEER_IP"
export MAYASCALE_BACKEND_PRIMARY_IP="$BACKEND_IP"
export MAYASCALE_BACKEND_SECONDARY_IP="$PEER_BACKEND_IP"

# System configuration (space-separated pairs for active-active)
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
echo "$(date): Terraform startup script completed - returning to cloud-init"

# The cluster_mayascale.sh script will:
# 1. Wait for essential services to be ready
# 2. Perform cluster initialization
# 3. Create /opt/mayastor/config/.cluster-configured when done
