#!/bin/bash

# MayaNAS Azure Unified Deployment Startup Script  
# Supports single node, active-passive, and active-active deployments

set -e

# Logging setup
umask 027
LOGFILE="/opt/mayastor/logs/mayanas-terraform-startup.log"
exec >> "$LOGFILE"
exec 2>&1

touch "$LOGFILE"
chmod 640 "$LOGFILE"
chown root:root "$LOGFILE"

echo "$(date): Starting MayaNAS ${deployment_type} deployment configuration..."

# Check and install Azure CLI if needed
if ! command -v az >/dev/null 2>&1; then
    echo "$(date): Azure CLI not found, installing..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash
    echo "$(date): Azure CLI installed successfully"
else
    echo "$(date): Azure CLI already available"
fi

# Variables from Terraform template
CLUSTER_NAME="${cluster_name}"
DEPLOYMENT_TYPE="${deployment_type}"
%{ if deployment_type == "single" ~}
NODE_ROLE="single"
%{ else ~}
NODE_ROLE="${node_role}"
VIP_ADDRESS="${vip_address}"
%{ if deployment_type == "active-active" ~}
VIP_ADDRESS_2="${vip_address_2}"
%{ endif ~}
BUCKET_COUNT="${bucket_count}"
%{ if node_count > 1 ~}
PEER_ZONE="${peer_zone}"
%{ endif ~}
METADATA_DISK_COUNT="${metadata_disk_count}"
STORAGE_SIZE_GB="${storage_size_gb}"
RESOURCE_ID="${resource_id}"
PEER_RESOURCE_ID="${peer_resource_id}"
AVAILABILITY_ZONE="${availability_zone}"
AZURE_REGION="${azure_region}"
RESOURCE_GROUP_NAME="${resource_group_name}"
%{ if node_count > 1 ~}
SECONDARY_RESOURCE_GROUP_NAME="${secondary_resource_group_name}"
%{ endif ~}
%{ endif ~}
BUCKET_NAMES="${bucket_names}"
METADATA_DISK_NAMES="${metadata_disk_names}"
S3_ACCESS_KEY="${s3_access_key}"
SSH_PUBLIC_KEY="${ssh_public_key}"

echo "Deployment: $DEPLOYMENT_TYPE, Cluster: $CLUSTER_NAME, Role: $NODE_ROLE"

# Check if already configured (run only on first boot)
if [ -f /opt/mayastor/config/.cluster-configured ]; then
    echo "$(date): MayaNAS already configured, skipping..."
    exit 0
fi

%{ if deployment_type != "single" && node_count > 1 ~}
# Only run cluster setup on PRIMARY node or node1 (depending on deployment type)
if [ "$DEPLOYMENT_TYPE" = "active-passive" ] && [ "$NODE_ROLE" != "primary" ]; then
    echo "$(date): Secondary node - cluster setup runs only on primary in active-passive"
    exit 0
elif [ "$DEPLOYMENT_TYPE" = "active-active" ] && [ "$NODE_ROLE" != "node1" ]; then
    echo "$(date): Node2 - cluster setup runs only on node1 in active-active"  
    exit 0
fi
%{ endif ~}

# Get zone and region information from Azure metadata with error handling
echo "$(date): Retrieving Azure instance metadata..."

ZONE=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/zone?api-version=2023-11-15&format=text" 2>/dev/null || echo "")
REGION=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/location?api-version=2023-11-15&format=text" 2>/dev/null || echo "unknown")

# Handle empty zone (many Azure regions don't have zones) - leave blank if not available
if [ "$ZONE" = "null" ]; then
    ZONE=""
fi

echo "Zone: $ZONE, Region: $REGION"

# Get instance information
INSTANCE_ID=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/vmId?api-version=2023-11-15&format=text" 2>/dev/null || echo "unknown")
INSTANCE_NAME=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/name?api-version=2023-11-15&format=text" 2>/dev/null || uname -n)
INTERNAL_IP=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?api-version=2023-11-15&format=text" 2>/dev/null || echo "unknown")
EXTERNAL_IP=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2023-11-15&format=text" 2>/dev/null || echo "")

echo "Instance: $INSTANCE_ID ($INSTANCE_NAME), Internal IP: $INTERNAL_IP"

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

# Install jq if needed
if ! command -v jq >/dev/null 2>&1; then
    echo "$(date): Installing jq..."
    apt-get update && apt-get install -y jq
fi

# Authenticate with managed identity and retrieve storage key (like ARM template)
echo "$(date): Authenticating with managed identity..."
for i in {1..5}; do
    if az login --identity 2>/dev/null; then
        echo "$(date): Managed identity authentication successful"
        break
    else
        echo "$(date): Managed identity auth attempt $i failed, retrying in 30s..."
        sleep 30
    fi
done

# Get resource group from metadata
RESOURCE_GROUP=$(curl -s -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/resourceGroupName?api-version=2023-11-15&format=text" 2>/dev/null || echo "${resource_group_name}")

# Retrieve storage access key at runtime (matching ARM template approach)
echo "$(date): Retrieving storage access key..."
STORAGE_ACCOUNT_NAME="$S3_ACCESS_KEY"
for i in {1..3}; do
    STORAGE_ACCESS_KEY=$(az storage account keys list --resource-group "$RESOURCE_GROUP" --account-name "$STORAGE_ACCOUNT_NAME" --query "[0].value" -o tsv 2>/dev/null || echo "")
    if [ -n "$STORAGE_ACCESS_KEY" ]; then
        echo "$(date): Storage access key retrieved successfully"
        break
    else
        echo "$(date): Key retrieval attempt $i failed, retrying in 15s..."
        sleep 15
    fi
done

if [ -z "$STORAGE_ACCESS_KEY" ]; then
    echo "$(date): ERROR: Could not retrieve storage access key"
    exit 1
fi

%{ if deployment_type == "single" ~}
# Single node deployment - simplified setup
export MAYANAS_CLUSTER_NAME="$CLUSTER_NAME"
export MAYANAS_NODE_ROLE="single"
export MAYANAS_VIP_ADDRESS="$INTERNAL_IP"  # For single node, VIP = internal IP
export MAYANAS_PRIMARY_INSTANCE="$INSTANCE_NAME"
export MAYANAS_SECONDARY_INSTANCE="$INSTANCE_NAME"  # Same instance for single node
export MAYANAS_PRIMARY_IP="$INTERNAL_IP"
export MAYANAS_SECONDARY_IP="$INTERNAL_IP"  # Same IP for single node
export MAYANAS_ZONE="$ZONE"
export MAYANAS_REGION="$REGION"
export MAYANAS_CLOUD_PROVIDER="azure"

# Export all buckets and disks for single node (space-separated lists)
export MAYANAS_S3_BUCKET="$BUCKET_NAMES"
export MAYANAS_METADATA_DISK="$METADATA_DISK_NAMES"

echo "$(date): Single node environment configured"
echo "Instance: $INSTANCE_NAME, IP: $INTERNAL_IP"
echo "Buckets: $BUCKET_NAMES, Metadata Disks: $METADATA_DISK_NAMES"

%{ else ~}
# HA deployment - complex setup
%{ if node_count > 1 ~}
# Set cluster peer information for HA deployments
export MAYANAS_CLUSTER_PEER_ZONE="$PEER_ZONE"
%{ endif ~}

# Set MayaNAS environment variables
export MAYANAS_CLUSTER_NAME="$CLUSTER_NAME"
export MAYANAS_NODE_ROLE="$NODE_ROLE"  
export MAYANAS_VIP_ADDRESS="$VIP_ADDRESS"
%{ if deployment_type == "active-active" ~}
export MAYANAS_VIP_ADDRESS_2="$VIP_ADDRESS_2"
%{ endif ~}

# Get actual instance hostnames (Azure uses internal DNS names)
PRIMARY_INSTANCE=$(uname -n)

%{ if node_count > 1 ~}
# Get peer IP from Terraform (secondary instance private IP)
PEER_IP="${secondary_private_ip}"
echo "$(date): Using peer IP from Terraform: $PEER_IP"

# Get secondary hostname directly from Terraform (more reliable than reverse DNS)
SECONDARY_INSTANCE="${secondary_instance_name}"
echo "$(date): Using secondary hostname from Terraform: $SECONDARY_INSTANCE"
%{ else ~}
# Single node: secondary same as primary  
SECONDARY_INSTANCE="$PRIMARY_INSTANCE"
# Single node: peer IP same as internal IP
PEER_IP="$INTERNAL_IP"
%{ endif ~}
%{ endif ~}

%{ if deployment_type != "single" ~}
# Export environment variables for MayaNAS HA setup script (matching AWS patterns)
export MAYANAS_CLUSTER_NAME="${cluster_name}"
export MAYANAS_S3_ACCESS_KEY="${s3_access_key}"
export MAYANAS_S3_SECRET_KEY="$STORAGE_ACCESS_KEY"
export MAYANAS_PRIMARY_INSTANCE="$PRIMARY_INSTANCE"
export MAYANAS_SECONDARY_INSTANCE="$SECONDARY_INSTANCE"
export MAYANAS_PRIMARY_IP="$INTERNAL_IP"
export MAYANAS_SECONDARY_IP="$PEER_IP"
export MAYANAS_PRIMARY_ZONE="$ZONE"
%{ if node_count > 1 ~}
export MAYANAS_SECONDARY_ZONE="$PEER_ZONE"
%{ endif ~}
%{ else ~}
# Single node - basic credentials and instance info already exported above
export MAYANAS_S3_ACCESS_KEY="$S3_ACCESS_KEY"
export MAYANAS_S3_SECRET_KEY="$STORAGE_ACCESS_KEY"
%{ endif ~}

%{ if deployment_type != "single" ~}
%{ if deployment_type == "active-active" ~}
# Active-active: space-separated arrays (matching AWS active-active template)
export MAYANAS_RESOURCE_ID="${resource_id} ${peer_resource_id}"
export MAYANAS_VIP_ADDRESS="${vip_address} ${vip_address_2}"
export MAYANAS_S3_BUCKET="${bucket_node1} ${bucket_node2}"
export MAYANAS_METADATA_DISK="${metadata_disk_node1} ${metadata_disk_node2}"
%{ else ~}
# Active-passive: space-separated lists (matching AWS active-passive template)
export MAYANAS_RESOURCE_ID="${resource_id}"
export MAYANAS_ROUTE_TABLE="mayascale-route-table-${resource_id}"
export MAYANAS_VIP_ADDRESS="${vip_address}"
export MAYANAS_S3_BUCKET="${bucket_names}"
export MAYANAS_METADATA_DISK="${metadata_disk_names}"
%{ endif ~}

# Additional variables for HA marketplace compatibility
export MAYANAS_BUCKET_NAMES="${bucket_names}"
export MAYANAS_BUCKET_COUNT="${bucket_count}"
export MAYANAS_METADATA_DISK_NAMES="${metadata_disk_names}"
export MAYANAS_METADATA_DISK_COUNT="${metadata_disk_count}"
export MAYANAS_METADATA_DISK_SIZE="${metadata_disk_size_gb}G"
export MAYANAS_S3_BUCKET_SIZE="${storage_size_gb}G"

%{ else ~}
# Single node - additional variables for compatibility
export MAYANAS_BUCKET_NAMES="$BUCKET_NAMES"
export MAYANAS_METADATA_DISK_NAMES="$METADATA_DISK_NAMES"
%{ endif ~}

export MAYANAS_DEPLOYMENT_TYPE="${deployment_type}"
export MAYANAS_CLOUD_PROVIDER="azure"
export MAYANAS_REGION="$REGION"
export MAYANAS_PROJECT_ID="$RESOURCE_GROUP_NAME"  # Azure equivalent of GCP PROJECT_ID - required for all deployments
%{ if mayanas_startup_wait != "" ~}
export MAYANAS_STARTUP_WAIT="${mayanas_startup_wait}"
%{ endif ~}
%{ if enable_lustre ~}

# Lustre protocol configuration
export MAYANAS_ENABLE_LUSTRE="true"
export MAYANAS_LUSTRE_FSNAME="${lustre_fsname}"
export MAYANAS_LUSTRE_DOM_THRESHOLD="${lustre_dom_threshold}"
# MDT disk name (used by cluster_setup2.sh to find the disk via Azure IMDS)
export MAYANAS_LUSTRE_MDT_DISK="${lustre_mdt_disk_name}"
%{ endif ~}

%{ if deployment_type == "single" ~}
# Single node - credentials already configured above
echo "$(date): Using Azure storage credentials for storage access..."

# Web UI is always available
echo "$(date): Web UI will be available at http://$EXTERNAL_IP:2020/"

%{ else ~}
# HA deployments - credentials provided by terraform
echo "$(date): Using Azure storage credentials for storage access..."

%{ if node_count > 1 ~}
# Smart VIP collision detection and assignment (matching AWS template logic)
echo "$(date): Performing smart VIP collision detection..."

# Function to check if IP is available
check_ip_available() {
    local test_ip="$1"
    
    # Check if IP responds to ping
    if ping -c 1 -W 2 "$test_ip" >/dev/null 2>&1; then
        return 1  # IP responds, likely taken
    fi
    
    return 0  # IP appears available
}

# Validate VIP addresses
%{ if deployment_type == "active-active" ~}
for vip in "$VIP_ADDRESS" "$VIP_ADDRESS_2"; do
    if ! check_ip_available "$vip"; then
        echo "$(date): WARNING: VIP $vip may already be in use"
    else
        echo "$(date): VIP $vip appears available"
    fi
done
%{ else ~}
if ! check_ip_available "$VIP_ADDRESS"; then
    echo "$(date): WARNING: VIP $VIP_ADDRESS may already be in use"  
else
    echo "$(date): VIP $VIP_ADDRESS appears available"
fi
%{ endif ~}
%{ endif ~}
%{ endif ~}

# Install Azure CLI and jq if not already installed
echo "$(date): Ensuring required packages are installed..."
if ! command -v jq >/dev/null 2>&1; then
    apt-get update && apt-get install -y jq
fi

# Configure Azure CLI for managed identity
echo "$(date): Configuring Azure CLI for managed identity..."
# Wait a moment for managed identity to be fully available
sleep 10
if ! az login --identity; then
    echo "$(date): WARNING: Managed identity login failed, will retry later"
    echo "$(date): This may be normal during initial deployment while identity propagates"
else
    echo "$(date): Managed identity login successful"
    echo "$(date): Verifying subscription access..."
    az account show --query "{subscription:name, subscriptionId:id, tenantId:tenantId}" -o table || echo "$(date): WARNING: Limited subscription access"
fi

echo "$(date): Validating Environment Variables..."
echo "MAYANAS_CLUSTER_NAME: $MAYANAS_CLUSTER_NAME"
echo "MAYANAS_S3_ACCESS_KEY: $MAYANAS_S3_ACCESS_KEY"
echo "MAYANAS_PRIMARY_INSTANCE: $MAYANAS_PRIMARY_INSTANCE"
echo "MAYANAS_SECONDARY_INSTANCE: $MAYANAS_SECONDARY_INSTANCE"
echo "MAYANAS_PRIMARY_IP: $MAYANAS_PRIMARY_IP"
echo "MAYANAS_SECONDARY_IP: $MAYANAS_SECONDARY_IP"
echo "MAYANAS_CLOUD_PROVIDER: $MAYANAS_CLOUD_PROVIDER"

echo "MAYANAS_S3_SECRET_KEY: (retrieved at runtime via managed identity)"

echo "MAYANAS_RESOURCE_ID: $MAYANAS_RESOURCE_ID"
echo "MAYANAS_VIP_ADDRESS: $MAYANAS_VIP_ADDRESS"
echo "MAYANAS_S3_BUCKET: $MAYANAS_S3_BUCKET"
echo "MAYANAS_METADATA_DISK: $MAYANAS_METADATA_DISK"
echo "MAYANAS_REGION: $MAYANAS_REGION"

# Create startup config exactly like AWS template
%{ if deployment_type == "single" ~}
cat > /opt/mayastor/config/.startup-config <<EOF
#!/bin/bash
# MayaNAS Deployment Context - Auto-generated by Terraform startup script
# Source this file to restore deployment environment: source /opt/mayastor/config/.startup-config

# Cluster configuration
export MAYANAS_CLUSTER_NAME="${cluster_name}"
export MAYANAS_NODE_ROLE="single"
export MAYANAS_DEPLOYMENT_TYPE="single"
export MAYANAS_CLOUD_PROVIDER="azure"
export MAYANAS_ZONE="$ZONE"
export MAYANAS_REGION="$REGION"

# Storage configuration
export MAYANAS_S3_BUCKET="$BUCKET_NAMES"
export MAYANAS_S3_BUCKET_NAMES="$BUCKET_NAMES"
export MAYANAS_METADATA_DISK="$METADATA_DISK_NAMES"
export MAYANAS_METADATA_DISK_NAMES="$METADATA_DISK_NAMES"

# Shares configuration
export MAYANAS_SHARES_CONFIG='${shares}'

# If empty or empty array, use default share1 with subnet CIDR
if [ -z "$MAYANAS_SHARES_CONFIG" ] || [ "$MAYANAS_SHARES_CONFIG" = "[]" ]; then
  export MAYANAS_SHARES_CONFIG='[{"name":"share1","recordsize":"1024K","export":"nfs","nfs_options":"${subnet_cidr}(rw,sync,no_subtree_check,no_root_squash)","smb_options":""}]'
fi

# Authentication
export MAYANAS_S3_ACCESS_KEY="$S3_ACCESS_KEY"
export MAYANAS_S3_SECRET_KEY="$STORAGE_ACCESS_KEY"
export MAYANAS_PROJECT_ID="$RESOURCE_GROUP_NAME"  # Azure equivalent of GCP PROJECT_ID
%{ if enable_lustre ~}

# Lustre protocol configuration
export MAYANAS_ENABLE_LUSTRE="true"
export MAYANAS_LUSTRE_FSNAME="${lustre_fsname}"
export MAYANAS_LUSTRE_DOM_THRESHOLD="${lustre_dom_threshold}"
# MDT disk name (used by cluster_setup2.sh to find the disk via Azure IMDS)
export MAYANAS_LUSTRE_MDT_DISK="${lustre_mdt_disk_name}"
%{ endif ~}

# Network configuration
export MAYANAS_EXTERNAL_IP="$EXTERNAL_IP"
export MAYANAS_INTERNAL_IP="$INTERNAL_IP"
export MAYANAS_INSTANCE_NAME="$INSTANCE_NAME"

# Deployment metadata
export MAYANAS_TERRAFORM_SAVED_AT="$(date -Iseconds)"

echo "Deployment context loaded: \$MAYANAS_CLUSTER_NAME (\$MAYANAS_DEPLOYMENT_TYPE)"
EOF
%{ else ~}
cat > /opt/mayastor/config/.startup-config <<EOF
#!/bin/bash
# MayaNAS Deployment Context - Auto-generated by Terraform startup script
# Source this file to restore deployment environment: source /opt/mayastor/config/.startup-config

# Cluster configuration
export MAYANAS_CLUSTER_NAME="${cluster_name}"
export MAYANAS_NODE_ROLE="${node_role}"
export MAYANAS_DEPLOYMENT_TYPE="${deployment_type}"
export MAYANAS_CLOUD_PROVIDER="azure"
export MAYANAS_ZONE="$ZONE"
export MAYANAS_REGION="$REGION"
export MAYANAS_AVAILABILITY_ZONE="$AVAILABILITY_ZONE"
%{ if node_count > 1 ~}
export MAYANAS_PEER_ZONE="$PEER_ZONE"
%{ endif ~}

# VIP configuration
%{ if deployment_type == "active-active" ~}
export MAYANAS_VIP_ADDRESS="${vip_address} ${vip_address_2}"
%{ else ~}
export MAYANAS_VIP_ADDRESS="${vip_address}"
%{ endif ~}

# Instance information
export MAYANAS_PRIMARY_INSTANCE="$PRIMARY_INSTANCE"
export MAYANAS_SECONDARY_INSTANCE="$SECONDARY_INSTANCE"
export MAYANAS_PRIMARY_IP="$INTERNAL_IP"
export MAYANAS_SECONDARY_IP="$PEER_IP"

# Resource configuration
%{ if deployment_type == "active-active" ~}
export MAYANAS_RESOURCE_ID="${resource_id} ${peer_resource_id}"
%{ else ~}
export MAYANAS_RESOURCE_ID="${resource_id}"
%{ endif ~}

# Storage configuration
%{ if deployment_type == "active-active" ~}
export MAYANAS_S3_BUCKET="${bucket_node1} ${bucket_node2}"
export MAYANAS_METADATA_DISK="${metadata_disk_node1} ${metadata_disk_node2}"
%{ else ~}
export MAYANAS_S3_BUCKET="${bucket_names}"
export MAYANAS_METADATA_DISK="${metadata_disk_names}"
%{ endif ~}
export MAYANAS_S3_BUCKET_NAMES="${bucket_names}"
export MAYANAS_METADATA_DISK_NAMES="${metadata_disk_names}"
# Per-node bucket count + size — needed by cluster_setup2.sh to slice
# MAYANAS_S3_BUCKET[node*BUCKET_COUNT..(node+1)*BUCKET_COUNT-1] per node.
export MAYANAS_BUCKET_COUNT="${bucket_count}"
export MAYANAS_S3_BUCKET_SIZE="${storage_size_gb}G"

# Shares configuration
export MAYANAS_SHARES_CONFIG='${shares}'

# Authentication
export MAYANAS_S3_ACCESS_KEY="${s3_access_key}"
export MAYANAS_S3_SECRET_KEY="$STORAGE_ACCESS_KEY"
export MAYANAS_PROJECT_ID="$RESOURCE_GROUP_NAME"  # Azure equivalent of GCP PROJECT_ID
%{ if enable_lustre ~}

# Lustre protocol configuration
export MAYANAS_ENABLE_LUSTRE="true"
export MAYANAS_LUSTRE_FSNAME="${lustre_fsname}"
export MAYANAS_LUSTRE_DOM_THRESHOLD="${lustre_dom_threshold}"
# MDT disk name (used by cluster_setup2.sh to find the disk via Azure IMDS)
export MAYANAS_LUSTRE_MDT_DISK="${lustre_mdt_disk_name}"
%{ endif ~}

# Network configuration
export MAYANAS_EXTERNAL_IP="$EXTERNAL_IP"
export MAYANAS_INTERNAL_IP="$INTERNAL_IP"
export MAYANAS_INSTANCE_NAME="$INSTANCE_NAME"

# Deployment metadata
export MAYANAS_TERRAFORM_SAVED_AT="$(date -Iseconds)"

echo "Deployment context loaded: \$MAYANAS_CLUSTER_NAME (\$MAYANAS_DEPLOYMENT_TYPE)"
EOF
%{ endif ~}

chmod +x /opt/mayastor/config/.startup-config
chown root:root /opt/mayastor/config/.startup-config
echo "$(date): Deployment context saved - source /opt/mayastor/config/.startup-config to restore"

# NFS/SMB shares configuration (JSON-encoded, must be exported BEFORE calling setup scripts)
export MAYANAS_SHARES_CONFIG='${shares}'

# Call appropriate MayaNAS setup script based on deployment type
%{ if deployment_type == "single" ~}
echo "$(date): Starting standalone MayaNAS setup..."
if [ -x /opt/mayastor/config/standalone_setup.sh ]; then
    echo "$(date): Launching MayaNAS standalone setup in background..."
    nohup /opt/mayastor/config/standalone_setup.sh > /opt/mayastor/logs/standalone-setup-background.log 2>&1 &
    SETUP_PID=$!
    echo "$(date): MayaNAS standalone setup launched with PID $SETUP_PID"
    echo "$(date): Monitor progress with: tail -f /opt/mayastor/logs/standalone-setup-background.log"
else
    echo "$(date): WARNING: standalone_setup.sh not found or not executable"
    touch /opt/mayastor/config/.cluster-configured
fi
%{ else ~}
# Call appropriate MayaNAS setup script based on deployment type (matching AWS template)
%{ if deployment_type == "active-active" ~}
MAYANAS_SETUP_SCRIPT="/opt/mayastor/config/cluster_setup2.sh"
if [ ! -x "$MAYANAS_SETUP_SCRIPT" ]; then
    echo "ERROR: MayaNAS setup script not found at $MAYANAS_SETUP_SCRIPT"
    exit 1
fi
echo "$(date): Launching MayaNAS active-active cluster setup in background..."
nohup $MAYANAS_SETUP_SCRIPT > /opt/mayastor/logs/cluster-setup-background.log 2>&1 &
SETUP_PID=$!
%{ else ~}
MAYANAS_SETUP_SCRIPT="/opt/mayastor/config/cluster_setup.sh"
if [ ! -x "$MAYANAS_SETUP_SCRIPT" ]; then
    echo "ERROR: MayaNAS setup script not found at $MAYANAS_SETUP_SCRIPT"
    exit 1
fi
echo "$(date): Launching MayaNAS active-passive cluster setup in background..."
nohup $MAYANAS_SETUP_SCRIPT > /opt/mayastor/logs/cluster-setup-background.log 2>&1 &
SETUP_PID=$!
%{ endif ~}
%{ endif ~}

# Set up mayanas user SSH access if key provided  
%{ if ssh_public_key != "" ~}
if id "mayanas" &>/dev/null; then
    echo "$(date): Setting up SSH access for mayanas user..."
    mkdir -p /home/mayanas/.ssh
    echo "${ssh_public_key}" >> /home/mayanas/.ssh/authorized_keys
    chmod 700 /home/mayanas/.ssh
    chmod 600 /home/mayanas/.ssh/authorized_keys
    chown -R mayanas:mayanas /home/mayanas/.ssh
    echo "$(date): SSH key added for mayanas user"
else
    echo "$(date): mayanas user not found, skipping SSH setup"
fi
%{ endif ~}

%{ if deployment_type != "single" ~}
echo "$(date): MayaNAS cluster setup launched with PID $SETUP_PID"
echo "$(date): Monitor progress with: tail -f /opt/mayastor/logs/cluster-setup-background.log"
%{ endif ~}

echo "$(date): MayaNAS ${deployment_type} startup configuration completed"

%{ if deployment_type == "single" ~}
# The standalone_setup.sh script will:
# 1. Configure single node MayaNAS deployment
# 2. Create /opt/mayastor/config/.cluster-configured when done
%{ else ~}
# The cluster_setup.sh script will:
# 1. Wait for essential services to be ready
# 2. Perform cluster initialization 
# 3. Create /opt/mayastor/config/.cluster-configured when done
# 4. Remove startup-script metadata to prevent re-runs
%{ endif ~}
