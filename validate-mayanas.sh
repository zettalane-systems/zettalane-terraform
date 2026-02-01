#!/bin/bash
#
# MayaNAS Validation Script
# Deploys MayaNAS storage + client, runs NFS tests, validates installation
#
# Usage: ./validate-mayanas.sh --cloud gcp --project-id PROJECT --zone ZONE
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging with timestamps
log()      { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
success()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $1"; }
warn()     { echo -e "${YELLOW}[$(date '+%H:%M:%S')] !${NC} $1"; }
fail()     { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $1"; }

# Azure-aware terraform apply with automatic retry for transient API errors
terraform_apply_with_retry() {
    local log_file="$1"
    local max_retries=5
    local retry_count=0
    local retry_delay=30

    while [ $retry_count -lt $max_retries ]; do
        retry_count=$((retry_count + 1))

        if [ $retry_count -gt 1 ]; then
            log "Retry attempt $retry_count/$max_retries (waiting ${retry_delay}s)..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))  # Exponential backoff
        fi

        # Run terraform apply
        if terraform apply -auto-approve >> "$log_file" 2>&1; then
            return 0
        fi

        # Check if error is Azure transient error (only Azure gets retry treatment)
        if [ "$CLOUD" = "azure" ]; then
            if grep -qE "HTTP response was nil|connection reset|connection refused|i/o timeout|TLS handshake timeout|context deadline exceeded|temporarily unavailable|InternalServerError|ServiceUnavailable|EOF" "$log_file"; then
                warn "Azure transient API error detected (attempt $retry_count/$max_retries)"
                if [ $retry_count -lt $max_retries ]; then
                    continue  # Retry
                fi
            fi
        fi

        # Non-transient error or non-Azure, fail immediately
        return 1
    done

    # Max retries exceeded
    fail "Terraform apply failed after $max_retries attempts"
    return 1
}

# Script directory (results dir set after cloud is known)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
CLOUD=""
PROJECT_ID=""
ZONE=""
KEY_PAIR_NAME=""
RESOURCE_GROUP=""
LOCATION=""
DEPLOYMENT_NAME="demo"
SKIP_DEPLOY="false"
TIER="standard"
MACHINE_TYPE=""
BUCKET_COUNT="1"
SKIP_CLIENT="false"
SSH_PUBLIC_KEY=""
DESTROY_MODE="false"
CLUSTER_TYPE="single"
USE_SPOT="false"

# Tier to machine type mapping
declare -A GCP_TIERS=( ["basic"]="n2-standard-4" ["standard"]="n2-standard-8" ["performance"]="n2-standard-16" )
declare -A AWS_TIERS=( ["basic"]="c6in.xlarge" ["standard"]="c6in.2xlarge" ["performance"]="c6in.4xlarge" )
declare -A AZURE_TIERS=( ["basic"]="Standard_D4s_v3" ["standard"]="Standard_D8s_v3" ["performance"]="Standard_D16s_v3" )

usage() {
    cat <<EOF
MayaNAS Validation Script

Usage: $0 --cloud PROVIDER [OPTIONS]

REQUIRED:
    --cloud PROVIDER          Cloud provider: gcp, aws, or azure

GCP OPTIONS:
    -p, --project-id PROJECT  GCP project ID (required)
    --zone ZONE               GCP zone (default: us-central1-a)

AWS OPTIONS:
    --key-pair KEY_PAIR       AWS EC2 Key Pair name (required)
    --zone AZ                 AWS availability zone (optional)

AZURE OPTIONS:
    --resource-group RG       Azure resource group name (required)
    --location LOCATION       Azure location (e.g., eastus)

COMMON OPTIONS:
    -n, --name NAME           Deployment name (default: demo)
    --cluster TYPE            Cluster type: single, ha (default: single)
    -t, --tier TIER           Performance tier: basic, standard, performance (default: standard)
    -m, --machine-type TYPE   Override machine type (cloud-specific)
    -b, --bucket-count COUNT  Number of cloud storage buckets (default: 1)
    --ssh-key PATH            SSH public key file (default: ~/.ssh/id_rsa.pub)
    --spot                    Use spot/preemptible instances (default)
    --spot                    Use spot/preemptible instances (default: on-demand)
    --skip-deploy             Skip terraform apply, validate existing deployment
    --skip-client             Skip client deployment, storage-only validation
    -d, --destroy             Destroy all resources and exit
    -h, --help                Show this help

CLUSTER TYPES:
    single    Single node NFS server
    ha        High availability (active-active with dual VIPs)

PERFORMANCE TIERS:
    Tier          GCP              AWS              Azure
    basic         n2-standard-4    c6in.xlarge      Standard_D4s_v3
    standard      n2-standard-8    c6in.2xlarge     Standard_D8s_v3
    performance   n2-standard-16   c6in.4xlarge     Standard_D16s_v3

EXAMPLES:
    # GCP with standard tier
    $0 --cloud gcp --project-id my-project --zone us-central1-a

    # AWS with performance tier
    $0 --cloud aws --key-pair my-keypair --tier performance

    # Azure with custom machine type
    $0 --cloud azure --resource-group mayanas-rg --location eastus -m Standard_D32s_v3

    # GCP with HA cluster
    $0 --cloud gcp --project-id my-project --zone us-central1-a --cluster ha

    # GCP with multiple buckets
    $0 --cloud gcp --project-id my-project --zone us-central1-a -b 4

    # Destroy all resources
    $0 --cloud gcp --project-id my-project -d
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cloud)
            CLOUD="$2"
            shift 2
            ;;
        --project-id|-p)
            PROJECT_ID="$2"
            shift 2
            ;;
        --zone|-z)
            ZONE="$2"
            shift 2
            ;;
        --key-pair|-k)
            KEY_PAIR_NAME="$2"
            shift 2
            ;;
        --resource-group|-g)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        --location|-l)
            LOCATION="$2"
            shift 2
            ;;
        --name|-n)
            DEPLOYMENT_NAME="$2"
            shift 2
            ;;
        --cluster)
            CLUSTER_TYPE="$2"
            shift 2
            ;;
        --tier|-t)
            TIER="$2"
            shift 2
            ;;
        --machine-type|-m)
            MACHINE_TYPE="$2"
            shift 2
            ;;
        --bucket-count|-b)
            BUCKET_COUNT="$2"
            shift 2
            ;;
        --ssh-key)
            SSH_PUBLIC_KEY_FILE="$2"
            shift 2
            ;;
        --spot)
            USE_SPOT="true"
            shift
            ;;
        --skip-deploy)
            SKIP_DEPLOY="true"
            shift
            ;;
        --skip-client)
            SKIP_CLIENT="true"
            shift
            ;;
        -d|--destroy)
            DESTROY_MODE="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            fail "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$CLOUD" ]; then
    fail "Missing required argument: --cloud"
    usage
fi

# Validate cluster type
if [[ ! "$CLUSTER_TYPE" =~ ^(single|ha)$ ]]; then
    fail "Invalid cluster type: $CLUSTER_TYPE (use single or ha)"
    exit 1
fi

# Map cluster type to terraform deployment_type
if [ "$CLUSTER_TYPE" = "ha" ]; then
    DEPLOYMENT_TYPE="active-active"
else
    DEPLOYMENT_TYPE="single"
fi

# Validate tier
if [[ ! "$TIER" =~ ^(basic|standard|performance)$ ]]; then
    fail "Invalid tier: $TIER (use basic, standard, or performance)"
    exit 1
fi

# Check prerequisites
if ! command -v terraform &>/dev/null; then
    fail "terraform not found. Install from https://terraform.io/downloads"
    exit 1
fi

if [ ! -d "$SCRIPT_DIR/$CLOUD/mayanas" ]; then
    fail "Terraform module not found: $SCRIPT_DIR/$CLOUD/mayanas"
    exit 1
fi

# Set terraform directory and resolve machine type
case "$CLOUD" in
    gcp)
        TF_DIR="$SCRIPT_DIR/gcp/mayanas"
        if [ -z "$PROJECT_ID" ]; then
            fail "GCP requires --project-id"
            usage
        fi
        # Default zone if not specified
        ZONE="${ZONE:-us-central1-a}"
        SSH_USER="mayanas"
        RESOLVED_MACHINE_TYPE="${MACHINE_TYPE:-${GCP_TIERS[$TIER]}}"
        ;;
    aws)
        TF_DIR="$SCRIPT_DIR/aws/mayanas"
        if [ -z "$KEY_PAIR_NAME" ]; then
            fail "AWS requires --key-pair"
            usage
        fi
        SSH_USER="ec2-user"
        RESOLVED_MACHINE_TYPE="${MACHINE_TYPE:-${AWS_TIERS[$TIER]}}"
        ;;
    azure)
        TF_DIR="$SCRIPT_DIR/azure/mayanas"
        if [ -z "$RESOURCE_GROUP" ]; then
            fail "Azure requires --resource-group"
            usage
        fi
        SSH_USER="azureuser"
        RESOLVED_MACHINE_TYPE="${MACHINE_TYPE:-${AZURE_TIERS[$TIER]}}"
        ;;
    *)
        fail "Unknown cloud provider: $CLOUD (use gcp, aws, or azure)"
        exit 1
        ;;
esac

# Load SSH public key
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"
if [ -f "$SSH_PUBLIC_KEY_FILE" ]; then
    SSH_PUBLIC_KEY=$(cat "$SSH_PUBLIC_KEY_FILE")
else
    warn "SSH public key not found: $SSH_PUBLIC_KEY_FILE"
    SSH_PUBLIC_KEY=""
fi

cd "$TF_DIR" || { fail "Cannot access terraform directory: $TF_DIR"; exit 1; }

# Create results directory with cloud prefix
RESULTS_DIR="$SCRIPT_DIR/mayanas-results/${CLOUD}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"
log "Results: $RESULTS_DIR"

# Handle destroy mode
if [ "$DESTROY_MODE" = "true" ]; then
    echo ""
    echo "========================================"
    echo " MayaNAS Destroy - ${CLOUD^^}"
    echo "========================================"
    echo ""

    # Destroy client first
    CLIENT_DIR="$SCRIPT_DIR/$CLOUD/client-testing"
    if [ -d "$CLIENT_DIR" ] && [ -f "$CLIENT_DIR/terraform.tfstate" ]; then
        log "Destroying client (log: $RESULTS_DIR/client_destroy.log)..."
        cd "$CLIENT_DIR"
        if terraform destroy -auto-approve > "$RESULTS_DIR/client_destroy.log" 2>&1; then
            rm -f terraform.tfstate terraform.tfstate.backup terraform.tfvars
            success "Client destroyed and state cleaned"
        else
            warn "Client destroy had errors - keeping tfstate for retry"
        fi
        cd "$TF_DIR"
    fi

    # Destroy storage with retry (Azure NIC reservation needs up to 180s)
    STORAGE_DESTROY_OK=false
    if [ -f "terraform.tfstate" ]; then
        log "Destroying storage (log: $RESULTS_DIR/storage_destroy.log)..."
        for attempt in 1 2 3; do
            if terraform destroy -auto-approve >> "$RESULTS_DIR/storage_destroy.log" 2>&1; then
                STORAGE_DESTROY_OK=true
                break
            fi
            if [ $attempt -lt 3 ]; then
                WAIT_TIME=$((attempt * 60))
                warn "Destroy attempt $attempt failed, retrying in ${WAIT_TIME}s..."
                sleep $WAIT_TIME
            fi
        done
        if [ "$STORAGE_DESTROY_OK" = true ]; then
            rm -f terraform.tfstate terraform.tfstate.backup terraform.tfvars
            success "Storage destroyed and state cleaned"
        else
            warn "Storage destroy failed after 3 attempts - keeping tfstate for retry"
            warn "Run with -d again to retry, or manually clean up resources"
        fi
    else
        log "No terraform.tfstate found, nothing to destroy"
    fi

    if [ "$STORAGE_DESTROY_OK" = true ]; then
        success "Cleanup complete"
    else
        fail "Cleanup incomplete - check logs and retry"
    fi
    exit 0
fi

echo ""
echo "========================================"
echo " MayaNAS Deployment - ${CLOUD^^}"
echo "========================================"
case "$CLOUD" in
    gcp)   echo " Project:      $PROJECT_ID" ;;
    aws)   echo " Region:       $(aws configure get region 2>/dev/null || echo 'default')" ;;
    azure) echo " Subscription: $(az account show --query name -o tsv 2>/dev/null || echo 'default')" ;;
esac
echo " Cluster:      $CLUSTER_TYPE"
echo " Tier:         $TIER"
echo " Machine Type: $RESOLVED_MACHINE_TYPE"
echo " Buckets:      $BUCKET_COUNT"
echo " Spot:         $USE_SPOT"
echo "========================================"
echo ""

# Deploy storage
if [ "$SKIP_DEPLOY" = "true" ]; then
    log "Skipping deployment (--skip-deploy specified)"
    if [ ! -f "terraform.tfstate" ]; then
        fail "No terraform.tfstate found. Run without --skip-deploy first."
        exit 1
    fi
elif [ -f "terraform.tfstate" ]; then
    # Check if deployment is complete by checking for node1_private_ip output
    EXISTING_IP=$(terraform output -raw node1_private_ip 2>/dev/null || echo "")
    if [ -n "$EXISTING_IP" ] && [ "$EXISTING_IP" != "null" ]; then
        log "Existing deployment found - reusing (run with -d to destroy first)"
    else
        warn "Incomplete deployment found - running apply to complete"
        # Initialize if needed
        if [ ! -d ".terraform" ]; then
            terraform init -upgrade > "$RESULTS_DIR/storage_init.log" 2>&1 || true
        fi
        log "Running terraform apply (log: $RESULTS_DIR/storage_apply.log)..."
        if ! terraform_apply_with_retry "$RESULTS_DIR/storage_apply.log"; then
            fail "Terraform apply failed - see $RESULTS_DIR/storage_apply.log"
            tail -20 "$RESULTS_DIR/storage_apply.log"
            exit 1
        fi
        success "Storage deployed"
    fi
else
    log "Generating terraform.tfvars..."

    case "$CLOUD" in
        gcp)
            REGION=$(echo "$ZONE" | sed 's/-[^-]*$//')
            cat > terraform.tfvars <<EOF
project_id = "$PROJECT_ID"
region = "$REGION"
cluster_name = "$DEPLOYMENT_NAME"
deployment_type = "$DEPLOYMENT_TYPE"
zones = ["$ZONE"]
machine_type = "$RESOLVED_MACHINE_TYPE"
bucket_count = $BUCKET_COUNT
use_spot_vms = $USE_SPOT
force_destroy_buckets = true

EOF
            ;;
        aws)
            cat > terraform.tfvars <<EOF
key_pair_name = "$KEY_PAIR_NAME"
cluster_name = "$DEPLOYMENT_NAME"
deployment_type = "$DEPLOYMENT_TYPE"
instance_type = "$RESOLVED_MACHINE_TYPE"
bucket_count = $BUCKET_COUNT
use_spot_instance = $USE_SPOT
ssh_cidr_blocks = ["0.0.0.0/0"]
force_destroy_buckets = true

EOF
            if [ -n "$ZONE" ]; then
                echo "availability_zone = \"$ZONE\"" >> terraform.tfvars
            fi
            ;;
        azure)
            # Get subscription ID for image reference
            AZURE_SUB_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")
            # Default location if not specified
            LOCATION="${LOCATION:-westus}"
            cat > terraform.tfvars <<EOF
subscription_id = "$AZURE_SUB_ID"
resource_group_name = "$RESOURCE_GROUP"
location = "$LOCATION"
cluster_name = "$DEPLOYMENT_NAME"
deployment_type = "$DEPLOYMENT_TYPE"
vm_size = "$RESOLVED_MACHINE_TYPE"
bucket_count = $BUCKET_COUNT
use_spot_instance = $USE_SPOT
ssh_cidr_blocks = ["0.0.0.0/0"]
$([ -n "$SSH_PUBLIC_KEY" ] && echo "ssh_public_key = \"$SSH_PUBLIC_KEY\"")


# Performance test share configuration
shares = [
  {
    name        = "demo-test"
    recordsize  = "1024K"
    export      = "nfs"
    nfs_options = "*(rw,sync,no_subtree_check,no_root_squash)"
    smb_options = "" 
  }
]

EOF
            ;;
    esac

    log "Running terraform init..."
    terraform init -upgrade > "$RESULTS_DIR/storage_init.log" 2>&1 || terraform init > "$RESULTS_DIR/storage_init.log" 2>&1

    log "Running terraform apply (log: $RESULTS_DIR/storage_apply.log)..."
    if ! terraform_apply_with_retry "$RESULTS_DIR/storage_apply.log"; then
        fail "Terraform apply failed - see $RESULTS_DIR/storage_apply.log"
        tail -20 "$RESULTS_DIR/storage_apply.log"
        exit 1
    fi
    success "Storage deployed"
fi

# Get storage outputs
log "Reading terraform outputs..."

# Save full outputs to file and check if valid
if ! terraform output -json > "$RESULTS_DIR/storage_outputs.json" 2>&1; then
    fail "Failed to read terraform outputs"
    cat "$RESULTS_DIR/storage_outputs.json"
    exit 1
fi

# Check if outputs file has actual content (not empty or just {})
OUTPUT_SIZE=$(wc -c < "$RESULTS_DIR/storage_outputs.json")
if [ "$OUTPUT_SIZE" -lt 10 ]; then
    warn "Terraform outputs are empty - deployment incomplete, running apply..."
    log "Running terraform apply (log: $RESULTS_DIR/storage_apply.log)..."
    if ! terraform_apply_with_retry "$RESULTS_DIR/storage_apply.log"; then
        fail "Terraform apply failed - see $RESULTS_DIR/storage_apply.log"
        tail -20 "$RESULTS_DIR/storage_apply.log"
        exit 1
    fi
    success "Storage deployed"
    # Re-read outputs
    terraform output -json > "$RESULTS_DIR/storage_outputs.json" 2>&1
fi

get_output() {
    terraform output -raw "$1" 2>/dev/null || echo ""
}

# Standard output names across all clouds
NODE1_IP=$(get_output node1_public_ip)
NODE1_INTERNAL_IP=$(get_output node1_private_ip)
VIP=$(get_output vip_address)

# Cloud-specific SSH command
case "$CLOUD" in
    gcp)
        NODE1_NAME=$(get_output node1_name)
        SSH_BASE="gcloud compute ssh mayanas@${NODE1_NAME} --zone=${ZONE} --project=${PROJECT_ID} --quiet --ssh-flag=-o --ssh-flag=StrictHostKeyChecking=no --ssh-flag=-o --ssh-flag=UserKnownHostsFile=/dev/null"
        ;;
    aws)
        if [ -f "$HOME/.ssh/${KEY_PAIR_NAME}.pem" ]; then
            SSH_BASE="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $HOME/.ssh/${KEY_PAIR_NAME}.pem ${SSH_USER}@${NODE1_IP}"
        else
            SSH_BASE="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${SSH_USER}@${NODE1_IP}"
        fi
        ;;
    azure)
        SSH_BASE="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${SSH_USER}@${NODE1_IP}"
        VNET_NAME=$(get_output virtual_network_name)
        SUBNET_NAME=$(get_output subnet_name)
        AZURE_SUB_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")
        ;;
esac

# NFS server address: use VIP if available, otherwise internal IP
NFS_SERVER="${VIP:-$NODE1_INTERNAL_IP}"

# SSH helper function
run_ssh() {
    if [ "$CLOUD" = "gcp" ]; then
        $SSH_BASE --command "$1"
    else
        $SSH_BASE "$1"
    fi
}

if [ -z "$NODE1_IP" ]; then
    fail "Could not get node1 IP address from terraform output"
    exit 1
fi

# Start client deployment in background (while we validate storage)
CLIENT_DEPLOY_PID=""
CLIENT_REUSED="false"
if [ "$SKIP_CLIENT" = "false" ]; then
    CLIENT_DIR="$SCRIPT_DIR/$CLOUD/client-testing"

    # Check if client already exists and is still running
    if [ -f "$CLIENT_DIR/terraform.tfstate" ]; then
        log "Existing client found - refreshing in background..."
        (
            cd "$CLIENT_DIR" || exit 1
            # Refresh state and apply to ensure instance exists (spot may have been terminated)
            terraform apply -auto-approve -refresh=true > "$RESULTS_DIR/client_refresh.log" 2>&1
        ) &
        CLIENT_DEPLOY_PID=$!
        CLIENT_REUSED="true"
    else
        log "Starting client deployment in background..."
        (
            cd "$CLIENT_DIR" || exit 1

            # Generate cloud-specific terraform.tfvars
            case "$CLOUD" in
                gcp)
                    # Client uses highcpu variant; double size for active-active
                    CLIENT_VCPUS=$(echo "$RESOLVED_MACHINE_TYPE" | grep -oE '[0-9]+$')
                    if [ "$CLUSTER_TYPE" = "ha" ]; then
                        CLIENT_VCPUS=$((CLIENT_VCPUS * 2))
                    fi
                    CLIENT_MACHINE_TYPE="n2-highcpu-${CLIENT_VCPUS}"
                    cat > terraform.tfvars <<EOFCLIENT
project_id = "$PROJECT_ID"
zone = "$ZONE"
client_name = "${DEPLOYMENT_NAME}-client"
machine_type = "$CLIENT_MACHINE_TYPE"
ssh_public_key = "$SSH_PUBLIC_KEY"
use_spot = $USE_SPOT
EOFCLIENT
                    ;;
                aws)
                    cat > terraform.tfvars <<EOFCLIENT
key_pair_name = "$KEY_PAIR_NAME"
client_name = "${DEPLOYMENT_NAME}-client"
ssh_public_key = "$SSH_PUBLIC_KEY"
use_spot = $USE_SPOT
EOFCLIENT
                    ;;
                azure)
                    cat > terraform.tfvars <<EOFCLIENT
subscription_id = "$AZURE_SUB_ID"
resource_group_name = "$RESOURCE_GROUP"
location = "$LOCATION"
client_name = "${DEPLOYMENT_NAME}-client"
ssh_public_key = "$SSH_PUBLIC_KEY"
vnet_name = "$VNET_NAME"
subnet_name = "$SUBNET_NAME"
use_spot = $USE_SPOT
EOFCLIENT
                    ;;
            esac

            terraform init -upgrade > "$RESULTS_DIR/client_init.log" 2>&1 || terraform init > "$RESULTS_DIR/client_init.log" 2>&1
            terraform apply -auto-approve > "$RESULTS_DIR/client_apply.log" 2>&1
        ) &
        CLIENT_DEPLOY_PID=$!
    fi
fi

echo ""
echo "========================================"
echo " MayaNAS Validation"
echo "========================================"
echo " Node1 IP: $NODE1_IP"
echo " VIP:      ${VIP:-N/A (single node)}"
echo " SSH User: $SSH_USER"
echo "========================================"
echo ""

# Test 1: SSH connectivity (with retry for instance boot)
log "Test 1: SSH connectivity (waiting for instance to be ready)..."
SSH_RETRIES=12
SSH_OK=false
for i in $(seq 1 $SSH_RETRIES); do
    if run_ssh "echo 'SSH OK'" >/dev/null 2>&1; then
        SSH_OK=true
        break
    fi
    if [ $i -lt $SSH_RETRIES ]; then
        echo -n "."
        sleep 10
    fi
done
echo ""

if [ "$SSH_OK" = true ]; then
    success "SSH connection established"
else
    fail "Cannot SSH to $NODE1_IP after ${SSH_RETRIES} attempts"
    echo ""
    echo "Debug with:"
    echo "  $SSH_BASE"
    exit 1
fi

# Test 2: Wait for MayaNAS cluster setup
log "Test 2: Waiting for MayaNAS cluster setup..."
MAX_WAIT=300
WAIT_INTERVAL=15
ELAPSED=0
CLUSTER_READY=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    # Check for setup completion marker
    if run_ssh "sudo test -f /opt/mayastor/config/.cluster-configured" >/dev/null 2>&1; then
        # Marker found, verify ZFS pool exists
        POOL_NAME=$(run_ssh "sudo zpool list -H -o name 2>/dev/null | head -1" 2>/dev/null || echo "")
        if [ -n "$POOL_NAME" ]; then
            CLUSTER_READY=true
            success "MayaNAS cluster ready (pool: $POOL_NAME)"
            break
        fi
    fi
    log "Waiting for cluster setup... (${ELAPSED}s/${MAX_WAIT}s)"
    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [ "$CLUSTER_READY" = false ]; then
    fail "MayaNAS cluster setup timed out after ${MAX_WAIT}s"
    echo "Check logs: sudo tail -f /opt/mayastor/logs/mayanas-terraform-startup.log"
    exit 1
fi

# Test 3: Storage pool info
log "Test 3: Storage pool info..."
POOL_INFO=$(run_ssh "sudo zpool list -H 2>/dev/null | head -1" 2>/dev/null || echo "")
if [ -n "$POOL_INFO" ]; then
    POOL_NAME=$(echo "$POOL_INFO" | awk '{print $1}')
    POOL_SIZE=$(echo "$POOL_INFO" | awk '{print $2}')
    POOL_FREE=$(echo "$POOL_INFO" | awk '{print $4}')
    POOL_HEALTH=$(echo "$POOL_INFO" | awk '{print $10}')
    success "Pool: $POOL_NAME  Size: $POOL_SIZE  Free: $POOL_FREE  Health: $POOL_HEALTH"
else
    warn "Could not get pool info"
fi

# Test 4: NFS exports
log "Test 4: NFS exports..."
EXPORTS=$(run_ssh "sudo exportfs -v 2>/dev/null | head -5" 2>/dev/null || echo "")
if [ -n "$EXPORTS" ]; then
    EXPORT_COUNT=$(echo "$EXPORTS" | wc -l)
    # Get first export path from exportfs output (format: /path/to/share  client(options))
    FIRST_EXPORT=$(echo "$EXPORTS" | head -1 | awk '{print $1}')
    # For NFSv4, strip /export prefix if present (fsid=0 root)
    NFS_EXPORT=$(echo "$FIRST_EXPORT" | sed 's|^/export||')
    success "NFS exports: $EXPORT_COUNT configured (${NFS_EXPORT})"
else
    warn "No NFS exports found - client test may fail"
    NFS_EXPORT=""
fi

# Test 5: Local fio test on storage
log "Test 5: Storage performance (local fio)..."
FIO_RESULT=$(run_ssh "cd /tmp && fio --name=quicktest --ioengine=libaio --direct=1 --rw=randread \
    --bs=4k --size=128M --numjobs=4 --runtime=10 --time_based --group_reporting \
    --output-format=json 2>/dev/null" 2>/dev/null || echo "")

if [ -n "$FIO_RESULT" ]; then
    READ_IOPS=$(echo "$FIO_RESULT" | jq -r '.jobs[0].read.iops // 0' 2>/dev/null | cut -d. -f1)
    if [ "$READ_IOPS" -gt 0 ] 2>/dev/null; then
        success "Local storage: ${READ_IOPS} IOPS"
    else
        warn "Could not parse fio results"
    fi
else
    warn "fio test skipped"
fi

# Wait for client deployment and run NFS tests
if [ "$SKIP_CLIENT" = "false" ]; then
    echo ""

    # Get client IP - either from reused deployment or wait for new one
    if [ "$CLIENT_REUSED" = "true" ]; then
        cd "$CLIENT_DIR"
        CLIENT_IP=$(terraform output -raw client_public_ip 2>/dev/null)
        cd "$TF_DIR"
        success "Client reused: $CLIENT_IP"
    elif [ -n "$CLIENT_DEPLOY_PID" ]; then
        log "Waiting for client deployment to complete..."
        if wait $CLIENT_DEPLOY_PID; then
            cd "$CLIENT_DIR"
            CLIENT_IP=$(terraform output -raw client_public_ip 2>/dev/null)
            cd "$TF_DIR"
            success "Client deployed: $CLIENT_IP"
            log "Waiting for client SSH to be ready..."
            sleep 30
        else
            warn "Client deployment failed - see $RESULTS_DIR/client_apply.log"
            CLIENT_IP=""
        fi
    fi

    if [ -n "$CLIENT_IP" ]; then

            CLIENT_SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 mayanas@${CLIENT_IP}"

            # Test 6: Copy and run NFS performance test
            log "Test 6: Running NFS performance test..."
            NFS_SCRIPT="$SCRIPT_DIR/nfs-performance-test.sh"

            if [ -z "$NFS_EXPORT" ]; then
                warn "No NFS export path available - skipping NFS performance test"
            elif [ -f "$NFS_SCRIPT" ]; then
                # Copy test script to client
                log "Uploading test script to client..."
                cat "$NFS_SCRIPT" | $CLIENT_SSH "cat > /tmp/nfs-test.sh && chmod +x /tmp/nfs-test.sh"

                # Run NFS performance test (output to screen + log)
                log "Testing NFS share: ${NFS_SERVER}:${NFS_EXPORT}"
                echo ""
                $CLIENT_SSH "sudo /tmp/nfs-test.sh --runtime 30 ${NFS_SERVER}:${NFS_EXPORT}" 2>&1 | tee "$RESULTS_DIR/nfs_performance.log"
                echo ""

                if [ ${PIPESTATUS[0]} -eq 0 ]; then
                    success "NFS performance test completed"
                else
                    warn "NFS performance test had errors"
                fi
            else
                warn "NFS test script not found: $NFS_SCRIPT"
            fi
    fi
fi

# Summary
echo ""
echo "========================================"
if [ "$CLUSTER_READY" = true ]; then
    echo -e " ${GREEN}Validation Complete${NC}"
else
    echo -e " ${YELLOW}Validation Complete (with warnings)${NC}"
fi
echo "========================================"
echo ""
echo " Connection details:"
echo "   cd $TF_DIR && terraform output deployment_summary"
echo ""
echo " Run again to rerun tests (reuses existing deployment)"
echo " Run with -d to destroy, then run again for fresh deployment"
echo ""
