#!/bin/bash

# MayaNAS Unified Startup Script  
# Supports single, active-passive, and active-active deployments
# Based on proven active-active and basic startup templates

set -e

# Logging setup - use MayaNAS logs directory only (no syslog)
umask 027  # Ensure log files are created with restrictive permissions
LOGFILE="/opt/mayastor/logs/mayanas-terraform-startup.log"
exec >> "$LOGFILE"
exec 2>&1

# Set proper ownership on log file
touch "$LOGFILE"
chmod 640 "$LOGFILE"
chown root:root "$LOGFILE"

echo "$(date): Starting MayaNAS ${deployment_type} deployment configuration..."

# Check and install gcloud CLI if needed (CVE mitigation)
if ! command -v gcloud >/dev/null 2>&1; then
    echo "$(date): gcloud CLI not found, installing..."
    dnf install -y google-cloud-cli
    echo "$(date): gcloud CLI installed successfully"
else
    echo "$(date): gcloud CLI already available"
fi

# Variables from Terraform template
CLUSTER_NAME="${cluster_name}"
DEPLOYMENT_TYPE="${deployment_type}"
NODE_ROLE="${node_role}"

%{ if deployment_type == "active-active" ~}
# Active-active specific variables
VIP_ADDRESS="${vip_address}"
VIP_ADDRESS_2="${vip_address_2}"
VIP_CIDR_RANGE="${vip_cidr_range}"
BUCKET_NAMES="${bucket_names}"
PEER_ZONE="${peer_zone}"
METADATA_DISK_NAMES="${metadata_disk_names}"
%{ else ~}
# Single/Active-passive specific variables  
VIP_CIDR_RANGE="${vip_cidr_range}"
TERRAFORM_VIP_ADDRESS="${vip_address}"
BUCKET_NAMES="${bucket_names}"
%{ if deployment_type != "single" ~}
PEER_ZONE="${peer_zone}"
%{ endif ~}
METADATA_DISK_NAMES="${metadata_disk_names}"
%{ endif ~}

# NFS/SMB shares configuration (JSON-encoded)
export MAYANAS_SHARES_CONFIG='${shares}'

# If empty or empty array, use default share1 with subnet CIDR
if [ -z "$MAYANAS_SHARES_CONFIG" ] || [ "$MAYANAS_SHARES_CONFIG" = "[]" ]; then
  export MAYANAS_SHARES_CONFIG='[{"name":"share1","recordsize":"1024K","export":"nfs","nfs_options":"${subnet_cidr}(rw,sync,no_subtree_check,no_root_squash)","smb_options":""}]'
fi

echo "Deployment: $DEPLOYMENT_TYPE, Cluster: $CLUSTER_NAME, Role: $NODE_ROLE"
%{ if deployment_type == "active-active" ~}
echo "VIP: $VIP_ADDRESS"
echo "VIP 2: $VIP_ADDRESS_2"
%{ else ~}
%{ if deployment_type != "single" ~}
echo "VIP CIDR Range: $VIP_CIDR_RANGE"
echo "Terraform Calculated VIP: $TERRAFORM_VIP_ADDRESS"
%{ endif ~}
%{ endif ~}

# Check if already configured (run only on first boot)
if [ -f /opt/mayastor/config/.cluster-configured ]; then
    echo "$(date): MayaNAS cluster already configured, skipping..."
    exit 0
fi

%{ if deployment_type == "single" ~}
# Single node - no cluster setup needed
echo "$(date): Single node deployment - basic setup only"
%{ else ~}
%{ if deployment_type == "active-active" ~}
# Active-active: Only run cluster setup on node1
if [ "$NODE_ROLE" != "node1" ]; then
    echo "$(date): Node2 - cluster setup runs only on node1 in active-active"
    exit 0
fi
%{ else ~}
# Active-passive: Only run cluster setup on primary node
if [ "$NODE_ROLE" != "primary" ]; then
    echo "$(date): Secondary node - cluster setup runs only on primary in active-passive"
    exit 0
fi
%{ endif ~}
%{ endif ~}

# Get zone first (needed for region calculation)
ZONE=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/zone | cut -d'/' -f4)

# Get instance name from metadata (hostname may not be set yet at boot)
INSTANCE_NAME=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/name)

%{ if deployment_type != "single" ~}
# Ensure subnet has secondary IP range for VIPs (HA deployments only)
echo "$(date): Checking subnet secondary IP range for VIPs..."
REGION=$(echo "$ZONE" | sed 's/-[^-]*$//')

# Get current subnet name
SUBNET_NAME=$(gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" \
    --format="value(networkInterfaces[0].subnetwork)" --quiet | cut -d'/' -f11)

echo "$(date): Using subnet: $SUBNET_NAME in region: $REGION"

# Ensure mayanas-alias-range secondary range exists for VIP
echo "$(date): Ensuring secondary IP range exists for VIP: $VIP_CIDR_RANGE"

# Check if mayanas-alias-range already exists
EXISTING_RANGE=$(gcloud compute networks subnets describe "$SUBNET_NAME" --region="$REGION" --format="value(secondaryIpRanges[].rangeName,secondaryIpRanges[].ipCidrRange)" | grep "mayanas-alias-range" | cut -f2 -d$'\t')

if [ -n "$EXISTING_RANGE" ]; then
    echo "$(date): Secondary range 'mayanas-alias-range' already exists with CIDR: $EXISTING_RANGE"
    if [ "$EXISTING_RANGE" != "$VIP_CIDR_RANGE" ]; then
        echo "WARNING: Existing range $EXISTING_RANGE conflicts with Terraform-assigned range $VIP_CIDR_RANGE"
        echo "$(date): Deleting conflicting range to use Terraform-assigned range"
        
        if gcloud compute networks subnets update "$SUBNET_NAME" \
            --region="$REGION" \
            --remove-secondary-ranges=mayanas-alias-range \
            --quiet; then
            echo "$(date): Successfully removed conflicting range $EXISTING_RANGE"
            
            # Now create the correct Terraform-assigned range
            echo "$(date): Creating Terraform-assigned range: mayanas-alias-range=$VIP_CIDR_RANGE"
            if gcloud compute networks subnets update "$SUBNET_NAME" \
                --region="$REGION" \
                --add-secondary-ranges=mayanas-alias-range="$VIP_CIDR_RANGE" \
                --quiet; then
                echo "$(date): Successfully created Terraform-assigned secondary IP range"
            else
                echo "ERROR: Failed to create Terraform-assigned secondary IP range"
                exit 1
            fi
        else
            echo "ERROR: Failed to remove conflicting range - cannot proceed"
            exit 1
        fi
    else
        echo "$(date): Existing range matches Terraform assignment - no changes needed"
    fi
else
    # No existing mayanas-alias-range, create it
    echo "$(date): Creating new secondary IP range: mayanas-alias-range=$VIP_CIDR_RANGE"
    if gcloud compute networks subnets update "$SUBNET_NAME" \
        --region="$REGION" \
        --add-secondary-ranges=mayanas-alias-range="$VIP_CIDR_RANGE" \
        --quiet; then
        echo "$(date): Successfully created secondary IP range"
    else
        echo "ERROR: Failed to create secondary IP range - cluster setup cannot proceed"
        exit 1
    fi
fi

%{ if deployment_type == "active-active" ~}
# Smart VIP collision detection and assignment (dual VIP for active-active)
echo "$(date): Performing smart VIP collision detection within range $VIP_CIDR_RANGE..."
RANGE_BASE=$(echo "$VIP_CIDR_RANGE" | cut -d'/' -f1 | cut -d'.' -f1-3)

# Get all currently assigned VIPs in this region's range
ASSIGNED_VIPS=$(gcloud compute instances list --filter="zone:($REGION*)" \
  --format='value(networkInterfaces[].aliasIpRanges[].ipCidrRange)' \
  --quiet 2>/dev/null | grep -E "^$RANGE_BASE\.[0-9]+/32$" | sed 's|/32||' || echo "")

echo "$(date): Currently assigned VIPs in range: $ASSIGNED_VIPS"

# VIP collision detection for this node's VIP
TERRAFORM_VIP_ADDRESS="$VIP_ADDRESS"
if [ -n "$TERRAFORM_VIP_ADDRESS" ]; then
  if ! echo "$ASSIGNED_VIPS" | grep -q "^$TERRAFORM_VIP_ADDRESS$"; then
    VIP_ADDRESS="$TERRAFORM_VIP_ADDRESS"
    echo "$(date): Using Terraform-calculated VIP: $VIP_ADDRESS (no collision detected)"
  else
    echo "$(date): Terraform-calculated VIP $TERRAFORM_VIP_ADDRESS is already in use, finding alternative..."
    # Find first available VIP
    VIP_ADDRESS=""
    for i in $(seq 1 254); do
      CANDIDATE_VIP="$RANGE_BASE.$i"
      if ! echo "$ASSIGNED_VIPS" | grep -q "^$CANDIDATE_VIP$"; then
        VIP_ADDRESS="$CANDIDATE_VIP"
        echo "$(date): Selected alternative VIP: $VIP_ADDRESS"
        break
      fi
    done
    if [ -z "$VIP_ADDRESS" ]; then
      echo "ERROR: No available VIP addresses in range $VIP_CIDR_RANGE"
      echo "All 254 addresses are assigned: $ASSIGNED_VIPS"
      exit 1
    fi
  fi
fi

# VIP collision detection for peer VIP (active-active only)
TERRAFORM_PEER_VIP="$VIP_ADDRESS_2"
if [ -n "$TERRAFORM_PEER_VIP" ]; then
  if ! echo "$ASSIGNED_VIPS" | grep -q "^$TERRAFORM_PEER_VIP$" && [ "$TERRAFORM_PEER_VIP" != "$VIP_ADDRESS" ]; then
    PEER_VIP_ADDRESS="$TERRAFORM_PEER_VIP"
    echo "$(date): Using Terraform-calculated peer VIP: $PEER_VIP_ADDRESS (no collision detected)"
  else
    echo "$(date): Terraform-calculated peer VIP $TERRAFORM_PEER_VIP conflicts, finding alternative..."
    # Find first available peer VIP (different from main VIP)
    PEER_VIP_ADDRESS=""
    for i in $(seq 1 254); do
      CANDIDATE_PEER_VIP="$RANGE_BASE.$i"
      if ! echo "$ASSIGNED_VIPS" | grep -q "^$CANDIDATE_PEER_VIP$" && [ "$CANDIDATE_PEER_VIP" != "$VIP_ADDRESS" ]; then
        PEER_VIP_ADDRESS="$CANDIDATE_PEER_VIP"
        echo "$(date): Selected alternative peer VIP: $PEER_VIP_ADDRESS"
        break
      fi
    done
    if [ -z "$PEER_VIP_ADDRESS" ]; then
      echo "ERROR: No available peer VIP addresses in range $VIP_CIDR_RANGE"
      echo "Node VIP is $VIP_ADDRESS, all other addresses assigned: $ASSIGNED_VIPS"
      exit 1
    fi
  fi
fi
%{ else ~}
# Smart VIP selection for active-passive: Try Terraform suggestion first, fallback to sequential search
echo "$(date): Performing smart VIP selection within range $VIP_CIDR_RANGE..."
RANGE_BASE=$(echo "$VIP_CIDR_RANGE" | cut -d'/' -f1 | cut -d'.' -f1-3)

# Get all currently assigned VIPs in this range
ASSIGNED_VIPS=$(gcloud compute instances list --filter="zone:($REGION*)" \
  --format='value(networkInterfaces[].aliasIpRanges[].ipCidrRange)' \
  --quiet 2>/dev/null | grep -E "^$RANGE_BASE\.[0-9]+/32$" | sed 's|/32||' || echo "")

echo "$(date): Currently assigned VIPs in range: $ASSIGNED_VIPS"

# Try Terraform-calculated VIP first  
VIP_ADDRESS=""
if [ -n "$TERRAFORM_VIP_ADDRESS" ]; then
  if ! echo "$ASSIGNED_VIPS" | grep -q "^$TERRAFORM_VIP_ADDRESS$"; then
    VIP_ADDRESS="$TERRAFORM_VIP_ADDRESS"
    echo "$(date): Using Terraform-calculated VIP: $VIP_ADDRESS (no collision detected)"
  else
    echo "$(date): Terraform-calculated VIP $TERRAFORM_VIP_ADDRESS is already in use, finding alternative..."
  fi
fi

# Fallback: Find first available VIP if collision occurred
if [ -z "$VIP_ADDRESS" ]; then
  for i in {1..254}; do
    CANDIDATE_VIP="$RANGE_BASE.$i"
    if ! echo "$ASSIGNED_VIPS" | grep -q "^$CANDIDATE_VIP$"; then
      VIP_ADDRESS="$CANDIDATE_VIP"
      echo "$(date): Selected alternative VIP: $VIP_ADDRESS (rare collision case - overriding Terraform calculation)"
      break
    fi
  done
fi

if [ -z "$VIP_ADDRESS" ]; then
  echo "ERROR: No available VIP addresses in range $VIP_CIDR_RANGE"
  echo "All 254 addresses are assigned: $ASSIGNED_VIPS"
  exit 1
fi
%{ endif ~}

# Update instance metadata with selected VIP(s)
echo "$(date): Updating instance metadata with selected VIP: $VIP_ADDRESS"
gcloud compute instances add-metadata "$(hostname)" --zone="$ZONE" \
  --metadata=mayanas-vip="$VIP_ADDRESS" --quiet

%{ if deployment_type == "active-active" ~}
echo "$(date): Updating instance metadata with selected peer VIP: $PEER_VIP_ADDRESS"
gcloud compute instances add-metadata "$(hostname)" --zone="$ZONE" \
  --metadata=mayanas-peer-vip="$PEER_VIP_ADDRESS" --quiet
%{ endif ~}

%{ endif ~}

# Get instance information (INSTANCE_NAME already set above)
PROJECT_ID=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/project/project-id)
INTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

%{ if deployment_type != "single" ~}
# Get peer node information for HA deployments
%{ if deployment_type == "active-active" ~}
# Active-active: node1 <-> node2
PRIMARY_INSTANCE="$CLUSTER_NAME-mayanas-node1-${random_suffix}"
SECONDARY_INSTANCE="$CLUSTER_NAME-mayanas-node2-${random_suffix}"
%{ else ~}
# Active-passive: primary <-> secondary  
PRIMARY_INSTANCE="$CLUSTER_NAME-mayanas-primary-${random_suffix}"
SECONDARY_INSTANCE="$CLUSTER_NAME-mayanas-secondary-${random_suffix}"
%{ endif ~}

# Get peer node internal IP
PEER_IP=$(gcloud compute instances describe "$SECONDARY_INSTANCE" \
    --zone="$PEER_ZONE" \
    --project="$PROJECT_ID" \
    --format="value(networkInterfaces[0].networkIP)" 2>/dev/null || echo "")
%{ endif ~}

# Export environment variables for MayaNAS cluster setup
export MAYANAS_CLUSTER_NAME="${cluster_name}"
export MAYANAS_NODE_ROLE="$NODE_ROLE"
export MAYANAS_DEPLOYMENT_TYPE="${deployment_type}"
export MAYANAS_CLOUD_PROVIDER="gcp"
export MAYANAS_ZONE="$ZONE"
export MAYANAS_PROJECT_ID="$PROJECT_ID"
export MAYANAS_INSTANCE_NAME="$INSTANCE_NAME"
%{ if mayanas_startup_wait != "" ~}
export MAYANAS_STARTUP_WAIT="${mayanas_startup_wait}"
%{ endif ~}
export MAYANAS_PRIMARY_INSTANCE="$PRIMARY_INSTANCE"
export MAYANAS_PRIMARY_IP="$INTERNAL_IP"
%{ if deployment_type == "single" ~}
# Single node: VIP = internal IP, resource ID from terraform
export MAYANAS_VIP_ADDRESS="$INTERNAL_IP"
export MAYANAS_RESOURCE_ID="${resource_id}"
%{ else ~}
export MAYANAS_SECONDARY_INSTANCE="$SECONDARY_INSTANCE"
export MAYANAS_SECONDARY_IP="$PEER_IP"
export MAYANAS_PEER_ZONE="${peer_zone}"
export MAYANAS_VIP_CIDR_RANGE="${vip_cidr_range}"
%{ if deployment_type == "active-active" ~}
# Active-active: space-separated VIPs and resource IDs
export MAYANAS_VIP_ADDRESS="$VIP_ADDRESS $PEER_VIP_ADDRESS"
export MAYANAS_RESOURCE_ID="${resource_id} ${peer_resource_id}"
%{ else ~}
# Active-passive: single VIP and resource ID
export MAYANAS_VIP_ADDRESS="$VIP_ADDRESS"
export MAYANAS_RESOURCE_ID="${resource_id}"
%{ endif ~}
%{ endif ~}
export MAYANAS_BUCKET_NAMES="${bucket_names}"
export MAYANAS_BUCKET_COUNT="${bucket_count}"
export MAYANAS_METADATA_DISK_NAMES="${metadata_disk_names}"

# Set environment variables expected by MayaNAS setup scripts
export MAYANAS_S3_BUCKET="${bucket_names}"
export MAYANAS_METADATA_DISK="${metadata_disk_names}"

# Authentication variables (GCS credentials for cloud storage access)
export MAYANAS_S3_ACCESS_KEY="${gcs_access_key}"
export MAYANAS_S3_SECRET_KEY="${gcs_secret_key}"

echo "$(date): Environment variables configured for MayaNAS cluster setup"

# Create startup configuration file for environment recreation
echo "$(date): Creating .startup-config file for environment recreation..."
mkdir -p /opt/mayastor/config
cat > /opt/mayastor/config/.startup-config <<EOF
#!/bin/bash
# MayaNAS Deployment Context - Auto-generated by Terraform startup script
# Date: $(date)
# Instance: $INSTANCE_NAME
# Zone: $ZONE

export MAYANAS_CLUSTER_NAME="${cluster_name}"
export MAYANAS_NODE_ROLE="$NODE_ROLE"
export MAYANAS_DEPLOYMENT_TYPE="${deployment_type}"
export MAYANAS_CLOUD_PROVIDER="gcp"
export MAYANAS_ZONE="$ZONE"
export MAYANAS_PROJECT_ID="$PROJECT_ID"
export MAYANAS_INSTANCE_NAME="$INSTANCE_NAME"
%{ if mayanas_startup_wait != "" ~}
export MAYANAS_STARTUP_WAIT="${mayanas_startup_wait}"
%{ endif ~}
export MAYANAS_PRIMARY_INSTANCE="$PRIMARY_INSTANCE"
export MAYANAS_PRIMARY_IP="$INTERNAL_IP"
%{ if deployment_type == "single" ~}
# Single node: VIP = internal IP, resource ID from terraform
export MAYANAS_VIP_ADDRESS="$INTERNAL_IP"
export MAYANAS_RESOURCE_ID="${resource_id}"
%{ else ~}
export MAYANAS_SECONDARY_INSTANCE="$SECONDARY_INSTANCE"
export MAYANAS_SECONDARY_IP="$PEER_IP"
export MAYANAS_PEER_ZONE="${peer_zone}"
export MAYANAS_VIP_CIDR_RANGE="${vip_cidr_range}"
%{ if deployment_type == "active-active" ~}
# Active-active: space-separated VIPs and resource IDs
export MAYANAS_VIP_ADDRESS="$VIP_ADDRESS $PEER_VIP_ADDRESS"
export MAYANAS_RESOURCE_ID="${resource_id} ${peer_resource_id}"
%{ else ~}
# Active-passive: single VIP and resource ID
export MAYANAS_VIP_ADDRESS="$VIP_ADDRESS"
export MAYANAS_RESOURCE_ID="${resource_id}"
%{ endif ~}
%{ endif ~}
export MAYANAS_BUCKET_NAMES="${bucket_names}"
export MAYANAS_BUCKET_COUNT="${bucket_count}"
export MAYANAS_METADATA_DISK_NAMES="${metadata_disk_names}"

# MayaNAS-expected environment variables
export MAYANAS_S3_BUCKET="${bucket_names}"
export MAYANAS_METADATA_DISK="${metadata_disk_names}"

# Authentication variables (GCS credentials)
export MAYANAS_S3_ACCESS_KEY="${gcs_access_key}"
export MAYANAS_S3_SECRET_KEY="${gcs_secret_key}"
EOF

chmod 640 /opt/mayastor/config/.startup-config
chown root:root /opt/mayastor/config/.startup-config
echo "$(date): Created .startup-config file successfully"

# Launch appropriate MayaNAS setup script based on deployment type
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
%{ if deployment_type == "active-active" ~}
# Active-active cluster setup
MAYANAS_SETUP_SCRIPT="/opt/mayastor/config/cluster_setup2.sh"
if [ -x "$MAYANAS_SETUP_SCRIPT" ]; then
    echo "$(date): Launching MayaNAS active-active cluster setup in background..."
    nohup $MAYANAS_SETUP_SCRIPT > /opt/mayastor/logs/cluster-setup-background.log 2>&1 &
    SETUP_PID=$!
    echo "$(date): MayaNAS cluster setup launched with PID $SETUP_PID"
    echo "$(date): Monitor progress with: tail -f /opt/mayastor/logs/cluster-setup-background.log"
else
    echo "$(date): WARNING: cluster_setup2.sh not found or not executable"
fi
%{ else ~}
# Active-passive cluster setup  
MAYANAS_SETUP_SCRIPT="/opt/mayastor/config/cluster_setup.sh"
if [ -x "$MAYANAS_SETUP_SCRIPT" ]; then
    echo "$(date): Launching MayaNAS cluster setup in background..."
    nohup $MAYANAS_SETUP_SCRIPT > /opt/mayastor/logs/cluster-setup-background.log 2>&1 &
    SETUP_PID=$!
    echo "$(date): MayaNAS cluster setup launched with PID $SETUP_PID"
    echo "$(date): Monitor progress with: tail -f /opt/mayastor/logs/cluster-setup-background.log"
else
    echo "$(date): WARNING: cluster_setup.sh not found or not executable"
fi
%{ endif ~}
%{ endif ~}

echo "$(date): MayaNAS startup script completed successfully"
