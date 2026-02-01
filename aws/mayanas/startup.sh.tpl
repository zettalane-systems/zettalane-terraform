#!/bin/bash

# MayaNAS AWS Unified Deployment Startup Script  
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
AWS_REGION="${aws_region}"
VPC_ID="${vpc_id}"
PRIMARY_SUBNET_ID="${primary_subnet_id}"
%{ if node_count > 1 ~}
SECONDARY_SUBNET_ID="${secondary_subnet_id}"
%{ endif ~}
%{ endif ~}
BUCKET_NAMES="${bucket_names}"
METADATA_DISK_NAMES="${metadata_disk_names}"
S3_ACCESS_KEY="${s3_access_key}"
S3_SECRET_KEY="${s3_secret_key}"
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

# Get zone and region information from AWS metadata
ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

echo "Zone: $ZONE, Region: $REGION"

# Get instance information
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
INSTANCE_NAME=$(uname -n)
INTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
EXTERNAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")

echo "Instance: $INSTANCE_ID, IP: $INTERNAL_IP"

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
export MAYANAS_CLOUD_PROVIDER="aws"

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

# Get actual instance hostnames (AWS uses internal DNS names)
PRIMARY_INSTANCE=$(uname -n)

%{ if node_count > 1 ~}
# Get peer IP from Terraform (secondary instance private IP)
PEER_IP="${secondary_private_ip}"
echo "$(date): Using peer IP from Terraform: $PEER_IP"

# Get secondary hostname via reverse DNS from its IP
SECONDARY_INSTANCE=$(host "$PEER_IP" | awk '{print $NF}' | sed 's/\.$//')

if [ -z "$SECONDARY_INSTANCE" ] || [ "$SECONDARY_INSTANCE" = "not" ]; then
    echo "$(date): Could not resolve hostname for IP $PEER_IP at startup, leaving unset"
    unset SECONDARY_INSTANCE
else
    echo "$(date): Resolved secondary hostname: $SECONDARY_INSTANCE from IP: $PEER_IP"
fi
%{ else ~}
# Single node: secondary same as primary  
SECONDARY_INSTANCE="$PRIMARY_INSTANCE"
# Single node: peer IP same as internal IP
PEER_IP="$INTERNAL_IP"
%{ endif ~}
%{ endif ~}

%{ if deployment_type != "single" ~}
# Export environment variables for MayaNAS HA setup script (matching GCP marketplace patterns)
export MAYANAS_CLUSTER_NAME="${cluster_name}"
export MAYANAS_S3_ACCESS_KEY="${s3_access_key}"
export MAYANAS_S3_SECRET_KEY="${s3_secret_key}"
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
export MAYANAS_S3_SECRET_KEY="$S3_SECRET_KEY"
export MAYANAS_PROJECT_ID="$PROJECT_ID"
%{ endif ~}

%{ if deployment_type != "single" ~}
%{ if deployment_type == "active-active" ~}
# Active-active: space-separated arrays (matching GCP active-active template)
export MAYANAS_RESOURCE_ID="${resource_id} ${peer_resource_id}"
export MAYANAS_VIP_ADDRESS="${vip_address} ${vip_address_2}"
export MAYANAS_S3_BUCKET="${bucket_node1} ${bucket_node2}"
export MAYANAS_METADATA_DISK="${metadata_disk_node1} ${metadata_disk_node2}"
%{ else ~}
# Active-passive: single values (matching GCP basic template)
export MAYANAS_RESOURCE_ID="${resource_id}"
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
export MAYANAS_CLOUD_PROVIDER="aws"
export MAYANAS_REGION="$REGION"

# Per-node resource assignment for active-active deployments
%{ if deployment_type == "active-active" ~}
if [ "$NODE_ROLE" = "node1" ]; then
    # Node 1 gets first half of resources (indices 0 to count-1)
    export MAYANAS_NODE_BUCKET_START="0"
    export MAYANAS_NODE_BUCKET_END="$((${bucket_count} - 1))"
    export MAYANAS_NODE_DISK_START="0"  
    export MAYANAS_NODE_DISK_END="$((${metadata_disk_count} - 1))"
else
    # Node 2 gets second half of resources (indices count to 2*count-1)
    export MAYANAS_NODE_BUCKET_START="${bucket_count}"
    export MAYANAS_NODE_BUCKET_END="$((${bucket_count} * 2 - 1))"
    export MAYANAS_NODE_DISK_START="${metadata_disk_count}"
    export MAYANAS_NODE_DISK_END="$((${metadata_disk_count} * 2 - 1))"
fi
%{ else ~}
# Active-Passive: All nodes share all resources
export MAYANAS_NODE_BUCKET_START="0"
export MAYANAS_NODE_BUCKET_END="$((${bucket_count} - 1))"
export MAYANAS_NODE_DISK_START="0"
export MAYANAS_NODE_DISK_END="$((${metadata_disk_count} - 1))"
%{ endif ~}

%{ if deployment_type == "single" ~}
# Single node - credentials already configured above
echo "$(date): Using S3-compatible credentials for storage access..."

# Web UI is always available
echo "$(date): Web UI will be available at http://$EXTERNAL_IP:2020/"

%{ else ~}
# HA deployments - credentials provided by terraform
echo "$(date): Using S3 credentials for storage access..."

%{ if node_count > 1 ~}
# Smart VIP collision detection and assignment (matching GCP marketplace template logic)
echo "$(date): Performing smart VIP collision detection..."

# Function to check if IP is available
check_ip_available() {
    local ip=$1
    echo "$(date): Checking IP availability: $ip"
    
    # Check if IP is assigned to any ENI in the VPC
    ASSIGNED_ENI=$(aws ec2 describe-network-interfaces \
        --region "$REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=private-ip-address,Values=$ip" \
        --query 'NetworkInterfaces[0].NetworkInterfaceId' \
        --output text 2>/dev/null)
    
    if [ "$ASSIGNED_ENI" != "None" ] && [ -n "$ASSIGNED_ENI" ]; then
        echo "$(date): IP $ip is assigned to ENI: $ASSIGNED_ENI"
        return 1  # IP is not available
    else
        echo "$(date): IP $ip is available"
        return 0  # IP is available
    fi
}

# Get subnet CIDR from Terraform template and calculate base IP
SUBNET_CIDR="${subnet_cidr}"

BASE_IP=$(echo "$SUBNET_CIDR" | cut -d'.' -f1-3)
echo "$(date): Subnet CIDR: $SUBNET_CIDR, Base IP: $BASE_IP"

# VIP collision detection for primary VIP
TERRAFORM_VIP_ADDRESS="$VIP_ADDRESS"
if [ -n "$TERRAFORM_VIP_ADDRESS" ]; then
  if check_ip_available "$VIP_ADDRESS"; then
    echo "$(date): Using Terraform-calculated VIP: $VIP_ADDRESS (no collision detected)"
  else
    echo "$(date): Terraform-calculated VIP $TERRAFORM_VIP_ADDRESS is already in use, finding alternative..."
    # Find first available VIP as fallback
    ORIGINAL_VIP="$VIP_ADDRESS"
    VIP_ADDRESS=""
    for i in $(seq 102 254); do
      CANDIDATE_VIP="$BASE_IP.$i"
      if check_ip_available "$CANDIDATE_VIP"; then
        VIP_ADDRESS="$CANDIDATE_VIP"
        echo "$(date): Selected alternative VIP: $VIP_ADDRESS (collision avoidance - was $ORIGINAL_VIP)"
        break
      fi
    done
    if [ -z "$VIP_ADDRESS" ]; then
      echo "ERROR: No available VIP addresses in subnet $SUBNET_CIDR"
      exit 1
    fi
  fi
fi

%{ if deployment_type == "active-active" ~}
# VIP collision detection for secondary VIP (active-active only)
TERRAFORM_VIP_ADDRESS_2="$VIP_ADDRESS_2"
if [ -n "$TERRAFORM_VIP_ADDRESS_2" ]; then
  if check_ip_available "$VIP_ADDRESS_2"; then
    echo "$(date): Using Terraform-calculated VIP2: $VIP_ADDRESS_2 (no collision detected)"
  else
    echo "$(date): Terraform-calculated VIP2 $TERRAFORM_VIP_ADDRESS_2 is already in use, finding alternative..."
    # Find first available VIP as fallback
    ORIGINAL_VIP_2="$VIP_ADDRESS_2"
    VIP_ADDRESS_2=""
    for i in $(seq 102 254); do
      CANDIDATE_VIP="$BASE_IP.$i"
      # Skip if it's the same as VIP_ADDRESS or already assigned
      if [ "$CANDIDATE_VIP" != "$VIP_ADDRESS" ] && check_ip_available "$CANDIDATE_VIP"; then
        VIP_ADDRESS_2="$CANDIDATE_VIP"
        echo "$(date): Selected alternative VIP2: $VIP_ADDRESS_2 (collision avoidance - was $ORIGINAL_VIP_2)"
        break
      fi
    done
    if [ -z "$VIP_ADDRESS_2" ]; then
      echo "ERROR: No available VIP2 addresses in subnet $SUBNET_CIDR"
      echo "VIP1 is $VIP_ADDRESS, no other addresses available"
      exit 1
    fi
  fi
fi
%{ endif ~}

# Update exports with collision-tested VIPs
export MAYANAS_VIP_ADDRESS="$VIP_ADDRESS"
%{ if deployment_type == "active-active" ~}
export MAYANAS_VIP_ADDRESS_2="$VIP_ADDRESS_2"
# Update space-separated VIP string for active-active
export MAYANAS_VIP_ADDRESS="$VIP_ADDRESS $VIP_ADDRESS_2"
%{ endif ~}

echo "$(date): Final VIP assignments - Primary: $VIP_ADDRESS%{ if deployment_type == "active-active" ~}, Secondary: $VIP_ADDRESS_2%{ endif ~}"
%{ endif ~}
%{ endif ~}

echo "$(date): Environment configured, starting MayaNAS setup..."

# Save deployment context before calling setup script (for recovery/debugging)
echo "$(date): Saving deployment context to /opt/mayastor/config/.startup-config..."
mkdir -p /opt/mayastor/config
%{ if deployment_type == "single" ~}
cat > /opt/mayastor/config/.startup-config <<EOF
#!/bin/bash
# MayaNAS Deployment Context - Auto-generated by Terraform startup script
# Source this file to restore deployment environment: source /opt/mayastor/config/.startup-config

# Cluster configuration
export MAYANAS_CLUSTER_NAME="${cluster_name}"
export MAYANAS_NODE_ROLE="single"
export MAYANAS_DEPLOYMENT_TYPE="single"
export MAYANAS_CLOUD_PROVIDER="aws"
export MAYANAS_ZONE="$ZONE"
export MAYANAS_REGION="$REGION"

# Storage configuration
export MAYANAS_S3_BUCKET="$BUCKET_NAMES"
export MAYANAS_METADATA_DISK="$METADATA_DISK_NAMES"

# Shares configuration
export MAYANAS_SHARES_CONFIG='${shares}'

# If empty or empty array, use default share1 with subnet CIDR
if [ -z "$MAYANAS_SHARES_CONFIG" ] || [ "$MAYANAS_SHARES_CONFIG" = "[]" ]; then
  export MAYANAS_SHARES_CONFIG='[{"name":"share1","recordsize":"1024K","export":"nfs","nfs_options":"${subnet_cidr}(rw,sync,no_subtree_check,no_root_squash)","smb_options":""}]'
fi

# Authentication
export MAYANAS_S3_ACCESS_KEY="$S3_ACCESS_KEY"
export MAYANAS_S3_SECRET_KEY="$S3_SECRET_KEY"
export MAYANAS_PROJECT_ID="$PROJECT_ID"

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
export MAYANAS_CLOUD_PROVIDER="aws"
export MAYANAS_ZONE="$ZONE"
export MAYANAS_REGION="$REGION"
export MAYANAS_AVAILABILITY_ZONE="$AVAILABILITY_ZONE"
%{ if node_count > 1 ~}
export MAYANAS_PEER_ZONE="${peer_zone}"
%{ endif ~}

# VIP configuration
export MAYANAS_VIP_ADDRESS="${vip_address}"
%{ if deployment_type == "active-active" ~}
export MAYANAS_VIP_ADDRESS_2="${vip_address_2}"
%{ endif ~}

# Storage configuration
%{ if deployment_type == "active-active" ~}
export MAYANAS_S3_BUCKET="${bucket_node1} ${bucket_node2}"
export MAYANAS_METADATA_DISK="${metadata_disk_node1} ${metadata_disk_node2}"
%{ else ~}
export MAYANAS_S3_BUCKET="${bucket_names}"
export MAYANAS_METADATA_DISK="${metadata_disk_names}"
%{ endif ~}
export MAYANAS_BUCKET_COUNT="${bucket_count}"
export MAYANAS_METADATA_DISK_COUNT="${metadata_disk_count}"
export MAYANAS_STORAGE_SIZE_GB="${storage_size_gb}"

# Shares configuration
export MAYANAS_SHARES_CONFIG='${shares}'

# Authentication
export MAYANAS_S3_ACCESS_KEY="${s3_access_key}"
export MAYANAS_S3_SECRET_KEY="${s3_secret_key}"

# Instance configuration (required by cluster setup scripts)
export MAYANAS_PRIMARY_INSTANCE="$PRIMARY_INSTANCE"
export MAYANAS_SECONDARY_INSTANCE="$SECONDARY_INSTANCE"
export MAYANAS_PRIMARY_IP="$INTERNAL_IP"
export MAYANAS_SECONDARY_IP="$PEER_IP"

# Network configuration
export MAYANAS_RESOURCE_ID="${resource_id}"
%{ if deployment_type == "active-active" ~}
export MAYANAS_PEER_RESOURCE_ID="${peer_resource_id}"
%{ endif ~}
export MAYANAS_VPC_ID="$VPC_ID"
export MAYANAS_PRIMARY_SUBNET_ID="$PRIMARY_SUBNET_ID"
%{ if node_count > 1 ~}
export MAYANAS_SECONDARY_SUBNET_ID="$SECONDARY_SUBNET_ID"
%{ endif ~}
export MAYANAS_INSTANCE_ID="$INSTANCE_ID"
export MAYANAS_INTERNAL_IP="$INTERNAL_IP"
export MAYANAS_EXTERNAL_IP="$EXTERNAL_IP"


# SSH configuration  
export MAYANAS_SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY"

# Deployment metadata
export MAYANAS_TERRAFORM_SAVED_AT="$(date -Iseconds)"

echo "Deployment context loaded: \$MAYANAS_CLUSTER_NAME (\$MAYANAS_DEPLOYMENT_TYPE) - Node: \$MAYANAS_NODE_ROLE"
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
# Call appropriate MayaNAS setup script based on deployment type (matching GCP marketplace patterns)
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
