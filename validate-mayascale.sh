#!/bin/bash
#
# MayaScale Validation Script
# Deploys MayaScale NVMe-oF storage + client, runs performance tests, validates installation
#
# Usage: ./validate-mayascale.sh --cloud gcp --project-id PROJECT --zone ZONE
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
success()  { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn()     { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $1"; }
fail()     { echo -e "${RED}[$(date '+%H:%M:%S')]${NC} $1"; }

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

# Script directory
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
POLICY="zonal-standard-performance"
MACHINE_TYPE=""
CLIENT_MACHINE_TYPE=""
SKIP_CLIENT="false"
SSH_PUBLIC_KEY=""
DESTROY_MODE="false"
USE_SPOT="false"

# Performance policy to machine type mapping
# GCP: n2-highcpu instances with local SSDs
declare -A GCP_POLICIES=(
    ["zonal-basic-performance"]="n2-highcpu-4"
    ["zonal-standard-performance"]="n2-highcpu-8"
    ["zonal-medium-performance"]="n2-highcpu-16"
    ["zonal-high-performance"]="n2-highcpu-32"
    ["zonal-ultra-performance"]="n2-highcpu-64"
    ["regional-basic-performance"]="n2-highcpu-4"
    ["regional-standard-performance"]="n2-highcpu-8"
    ["regional-medium-performance"]="n2-highcpu-16"
    ["regional-high-performance"]="n2-highcpu-32"
    ["regional-ultra-performance"]="n2-highcpu-64"
)

# AWS: i3en/i4i instances with NVMe storage
declare -A AWS_POLICIES=(
    ["zonal-basic-performance"]="i4i.xlarge"
    ["zonal-standard-performance"]="i3en.2xlarge"
    ["zonal-medium-performance"]="i3en.xlarge"
    ["zonal-high-performance"]="i3en.6xlarge"
    ["zonal-ultra-performance"]="i3en.12xlarge"
    ["regional-basic-performance"]="i4i.xlarge"
    ["regional-standard-performance"]="i3en.2xlarge"
    ["regional-medium-performance"]="i3en.xlarge"
    ["regional-high-performance"]="i3en.6xlarge"
    ["regional-ultra-performance"]="i3en.12xlarge"
)

# Azure: L-series VMs with local NVMe (Laosv4 recommended)
declare -A AZURE_POLICIES=(
    ["zonal-basic-performance"]="Standard_L2as_v4"
    ["zonal-standard-performance"]="Standard_L4aos_v4"
    ["zonal-medium-performance"]="Standard_L8aos_v4"
    ["zonal-high-performance"]="Standard_L24aos_v4"
    ["zonal-ultra-performance"]="Standard_L32aos_v4"
    ["regional-basic-performance"]="Standard_L2as_v4"
    ["regional-standard-performance"]="Standard_L4aos_v4"
    ["regional-medium-performance"]="Standard_L8aos_v4"
    ["regional-high-performance"]="Standard_L24aos_v4"
    ["regional-ultra-performance"]="Standard_L32aos_v4"
)

# Expected IOPS targets (80% of peak for SLA margin)
declare -A GCP_TARGETS=(
    ["zonal-basic-performance_write"]="55000"
    ["zonal-basic-performance_read"]="190000"
    ["zonal-standard-performance_write"]="110000"
    ["zonal-standard-performance_read"]="380000"
    ["zonal-medium-performance_write"]="175000"
    ["zonal-medium-performance_read"]="700000"
    ["zonal-high-performance_write"]="290000"
    ["zonal-high-performance_read"]="900000"
    ["zonal-ultra-performance_write"]="585000"
    ["zonal-ultra-performance_read"]="1130000"
    ["regional-basic-performance_write"]="50000"
    ["regional-basic-performance_read"]="170000"
    ["regional-standard-performance_write"]="99000"
    ["regional-standard-performance_read"]="340000"
    ["regional-medium-performance_write"]="157500"
    ["regional-medium-performance_read"]="650000"
    ["regional-high-performance_write"]="261000"
    ["regional-high-performance_read"]="900000"
    ["regional-ultra-performance_write"]="525000"
    ["regional-ultra-performance_read"]="1130000"
)

declare -A AWS_TARGETS=(
    ["zonal-basic-performance_write"]="57000"
    ["zonal-basic-performance_read"]="204000"
    ["zonal-standard-performance_write"]="135000"
    ["zonal-standard-performance_read"]="346000"
    ["zonal-medium-performance_write"]="175000"
    ["zonal-medium-performance_read"]="650000"
    ["zonal-high-performance_write"]="368000"
    ["zonal-high-performance_read"]="992000"
    ["zonal-ultra-performance_write"]="528000"
    ["zonal-ultra-performance_read"]="1350000"
    ["regional-basic-performance_write"]="50000"
    ["regional-basic-performance_read"]="200000"
    ["regional-standard-performance_write"]="120000"
    ["regional-standard-performance_read"]="350000"
    ["regional-medium-performance_write"]="157500"
    ["regional-medium-performance_read"]="650000"
    ["regional-high-performance_write"]="330000"
    ["regional-high-performance_read"]="1000000"
    ["regional-ultra-performance_write"]="475000"
    ["regional-ultra-performance_read"]="1350000"
)

declare -A AZURE_TARGETS=(
    ["zonal-basic-performance_write"]="55000"
    ["zonal-basic-performance_read"]="137500"
    ["zonal-standard-performance_write"]="144000"
    ["zonal-standard-performance_read"]="360000"
    ["zonal-medium-performance_write"]="288000"
    ["zonal-medium-performance_read"]="720000"
    ["zonal-high-performance_write"]="864000"
    ["zonal-high-performance_read"]="2160000"
    ["zonal-ultra-performance_write"]="1152000"
    ["zonal-ultra-performance_read"]="2880000"
    ["regional-basic-performance_write"]="46000"
    ["regional-basic-performance_read"]="137500"
    ["regional-standard-performance_write"]="120000"
    ["regional-standard-performance_read"]="360000"
    ["regional-medium-performance_write"]="240000"
    ["regional-medium-performance_read"]="720000"
    ["regional-high-performance_write"]="720000"
    ["regional-high-performance_read"]="2160000"
    ["regional-ultra-performance_write"]="960000"
    ["regional-ultra-performance_read"]="2880000"
)

usage() {
    cat <<EOF
MayaScale Validation Script

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
    --location LOCATION       Azure location (e.g., eastus, westus)

COMMON OPTIONS:
    -n, --name NAME           Deployment name (default: demo)
    -o, --policy POLICY       Performance policy (default: zonal-standard-performance)
    -m, --machine-type TYPE   Override storage machine type (cloud-specific)
    --client-machine-type TYPE  Override client machine type (cloud-specific)
    --ssh-key PATH            SSH public key file (default: ~/.ssh/id_rsa.pub)
    --spot                    Use spot/preemptible instances (default: on-demand)
    --skip-deploy             Skip terraform apply, validate existing deployment
    --skip-client             Skip client deployment, storage-only validation
    -d, --destroy             Destroy all resources and exit
    -h, --help                Show this help

PERFORMANCE POLICIES:
    zonal-*     Single availability zone (lower latency, no cross-zone replication)
    regional-*  Cross-zone HA (higher durability, ~10-17% write overhead)

    Policy                      GCP             AWS             Azure           Write IOPS   Read IOPS
    zonal-standard-performance  n2-highcpu-8    i3en.2xlarge    L4aos_v4        110-144K     360-380K
    zonal-medium-performance    n2-highcpu-16   i3en.xlarge     L8aos_v4        175-288K     650-720K
    zonal-high-performance      n2-highcpu-32   i3en.6xlarge    L24aos_v4       290-864K     900K-2.16M
    zonal-ultra-performance     n2-highcpu-64   i3en.12xlarge   L32aos_v4       585K-1.15M   1.13M-2.88M

EXAMPLES:
    # GCP with medium performance
    $0 --cloud gcp --project-id my-project --zone us-central1-a

    # AWS with high performance
    $0 --cloud aws --key-pair my-keypair -o zonal-high-performance

    # Azure with ultra performance
    $0 --cloud azure --resource-group mayascale-rg --location eastus -o zonal-ultra-performance

    # GCP with regional HA (cross-zone replication)
    $0 --cloud gcp --project-id my-project -o regional-medium-performance

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
        --policy|-o)
            POLICY="$2"
            shift 2
            ;;
        --machine-type|-m)
            MACHINE_TYPE="$2"
            shift 2
            ;;
        --client-machine-type)
            CLIENT_MACHINE_TYPE="$2"
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

# Validate policy
VALID_POLICIES="zonal-basic-performance zonal-standard-performance zonal-medium-performance zonal-high-performance zonal-ultra-performance regional-basic-performance regional-standard-performance regional-medium-performance regional-high-performance regional-ultra-performance"
if [[ ! " $VALID_POLICIES " =~ " $POLICY " ]]; then
    fail "Invalid policy: $POLICY"
    exit 1
fi

# Determine deployment type from policy
if [[ "$POLICY" =~ ^regional ]]; then
    DEPLOYMENT_TYPE="regional"
else
    DEPLOYMENT_TYPE="zonal"
fi

# Check prerequisites
if ! command -v terraform &>/dev/null; then
    fail "terraform not found. Install from https://terraform.io/downloads"
    exit 1
fi

if [ ! -d "$SCRIPT_DIR/$CLOUD/mayascale" ]; then
    fail "Terraform module not found: $SCRIPT_DIR/$CLOUD/mayascale"
    exit 1
fi

# Set terraform directory and resolve machine type
case "$CLOUD" in
    gcp)
        TF_DIR="$SCRIPT_DIR/gcp/mayascale"
        if [ -z "$PROJECT_ID" ]; then
            fail "GCP requires --project-id"
            usage
        fi
        ZONE="${ZONE:-us-central1-a}"
        SSH_USER="mayascale"
        RESOLVED_MACHINE_TYPE="${MACHINE_TYPE:-${GCP_POLICIES[$POLICY]}}"
        ;;
    aws)
        TF_DIR="$SCRIPT_DIR/aws/mayascale"
        if [ -z "$KEY_PAIR_NAME" ]; then
            fail "AWS requires --key-pair"
            usage
        fi
        SSH_USER="ec2-user"
        RESOLVED_MACHINE_TYPE="${MACHINE_TYPE:-${AWS_POLICIES[$POLICY]}}"
        ;;
    azure)
        TF_DIR="$SCRIPT_DIR/azure/mayascale"
        if [ -z "$RESOURCE_GROUP" ]; then
            fail "Azure requires --resource-group"
            usage
        fi
        SSH_USER="azureuser"
        LOCATION="${LOCATION:-westus}"
        RESOLVED_MACHINE_TYPE="${MACHINE_TYPE:-${AZURE_POLICIES[$POLICY]}}"
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

# Create results directory
RESULTS_DIR="$SCRIPT_DIR/mayascale-results/${CLOUD}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"
log "Results: $RESULTS_DIR"

# Handle destroy mode
if [ "$DESTROY_MODE" = "true" ]; then
    echo ""
    echo "========================================"
    echo " MayaScale Destroy - ${CLOUD^^}"
    echo "========================================"
    echo ""

    # Destroy client first
    CLIENT_DIR="$SCRIPT_DIR/$CLOUD/client-testing"
    CLIENT_DESTROY_OK=false
    if [ -d "$CLIENT_DIR" ] && [ -f "$CLIENT_DIR/terraform.tfstate" ]; then
        log "Destroying client (log: $RESULTS_DIR/client_destroy.log)..."
        cd "$CLIENT_DIR"
        if terraform destroy -auto-approve > "$RESULTS_DIR/client_destroy.log" 2>&1; then
            CLIENT_DESTROY_OK=true
            rm -f terraform.tfstate terraform.tfstate.backup terraform.tfvars
            success "Client destroyed and state cleaned"
        else
            warn "Client destroy had errors - keeping tfstate for retry"
        fi
        cd "$TF_DIR"
    fi

    # Destroy storage
    STORAGE_DESTROY_OK=false
    if [ -f "terraform.tfstate" ]; then
        log "Destroying storage (log: $RESULTS_DIR/storage_destroy.log)..."
        if terraform destroy -auto-approve > "$RESULTS_DIR/storage_destroy.log" 2>&1; then
            STORAGE_DESTROY_OK=true
            rm -f terraform.tfstate terraform.tfstate.backup terraform.tfvars
            success "Storage destroyed and state cleaned"
        else
            warn "Storage destroy had errors - keeping tfstate for retry"
            warn "Run with -d again to retry, or manually clean up resources"
        fi
    else
        log "No terraform.tfstate found, nothing to destroy"
    fi

    # After successful destroy, check for any orphaned resources
    if [ "$STORAGE_DESTROY_OK" = true ]; then
        log "Checking for orphaned resources..."
        case "$CLOUD" in
            gcp)
                # Delete any leftover resources with deployment prefix
                for type in instances firewall-rules; do
                    gcloud compute $type list --filter="name~^${DEPLOYMENT_NAME}" --format="value(name)" --project="$PROJECT_ID" 2>/dev/null | while read -r name; do
                        [ -n "$name" ] && log "Deleting orphaned $type: $name" && gcloud compute $type delete "$name" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                    done
                done
                # Subnets need region
                gcloud compute networks subnets list --filter="name~^${DEPLOYMENT_NAME}" --format="value(name,region)" --project="$PROJECT_ID" 2>/dev/null | while read -r name region; do
                    [ -n "$name" ] && log "Deleting orphaned subnet: $name" && gcloud compute networks subnets delete "$name" --region="$region" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                done
                # Networks
                gcloud compute networks list --filter="name~^${DEPLOYMENT_NAME}" --format="value(name)" --project="$PROJECT_ID" 2>/dev/null | while read -r name; do
                    [ -n "$name" ] && log "Deleting orphaned network: $name" && gcloud compute networks delete "$name" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                done
                # Placement policies need region
                gcloud compute resource-policies list --filter="name~^${DEPLOYMENT_NAME}" --format="value(name,region)" --project="$PROJECT_ID" 2>/dev/null | while read -r name region; do
                    [ -n "$name" ] && log "Deleting orphaned policy: $name" && gcloud compute resource-policies delete "$name" --region="$region" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                done
                # Service accounts
                gcloud iam service-accounts list --filter="email~^${DEPLOYMENT_NAME}" --format="value(email)" --project="$PROJECT_ID" 2>/dev/null | while read -r email; do
                    [ -n "$email" ] && log "Deleting orphaned SA: $email" && gcloud iam service-accounts delete "$email" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                done
                ;;
        esac
        success "Cleanup complete"
    else
        fail "Cleanup incomplete - check logs and retry"
    fi
    exit 0
fi

echo ""
echo "========================================"
echo " MayaScale Deployment - ${CLOUD^^}"
echo "========================================"
case "$CLOUD" in
    gcp)   echo " Project:      $PROJECT_ID" ;;
    aws)   echo " Region:       $(aws configure get region 2>/dev/null || echo 'default')" ;;
    azure) echo " Subscription: $(az account show --query name -o tsv 2>/dev/null || echo 'default')" ;;
esac
echo " Policy:       $POLICY"
echo " Machine Type: $RESOLVED_MACHINE_TYPE"
echo " Spot:         $USE_SPOT"

# Enable colocation for zonal policies (placement group)
ENABLE_COLOCATION="false"
if [[ "$POLICY" =~ ^zonal ]]; then
    ENABLE_COLOCATION="true"
    echo " Colocation:   enabled"
    if [ "$USE_SPOT" = "true" ]; then
        warn "Spot + colocation may fail if capacity unavailable. Retry without --spot if needed."
    fi
fi
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
    EXISTING_IP=$(terraform output -raw node1_private_ip 2>/dev/null || echo "")
    if [ -n "$EXISTING_IP" ] && [ "$EXISTING_IP" != "null" ]; then
        log "Existing deployment found - reusing (run with -d to destroy first)"
    else
        warn "Incomplete deployment found - running apply to complete"
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
performance_policy = "$POLICY"
zone = "$ZONE"
machine_type = "$RESOLVED_MACHINE_TYPE"
use_spot_vms = $USE_SPOT
EOF
            # Reserve client slot in placement policy for colocation
            if [ "$ENABLE_COLOCATION" = "true" ]; then
                echo "client_count = 1" >> terraform.tfvars
            fi
            ;;
        aws)
            AWS_AZ="${ZONE:-us-east-1a}"
            cat > terraform.tfvars <<EOF
key_pair_name = "$KEY_PAIR_NAME"
cluster_name = "$DEPLOYMENT_NAME"
performance_policy = "$POLICY"
instance_type_override = "$RESOLVED_MACHINE_TYPE"
use_spot_instances = $USE_SPOT
ssh_cidr_blocks = ["0.0.0.0/0"]
availability_zone = "$AWS_AZ"
EOF
            # AWS placement group auto-created for zonal non-spot
            ;;
        azure)
            AZURE_SUB_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")
            cat > terraform.tfvars <<EOF
subscription_id = "$AZURE_SUB_ID"
cluster_name = "$DEPLOYMENT_NAME"
location = "$LOCATION"
performance_policy = "$POLICY"
use_spot_instances = $USE_SPOT
$([ -n "$SSH_PUBLIC_KEY" ] && echo "ssh_public_key = \"$SSH_PUBLIC_KEY\"")
EOF
            if [ -n "$RESOURCE_GROUP" ]; then
                echo "resource_group_name = \"$RESOURCE_GROUP\"" >> terraform.tfvars
            fi
            # Azure PPG auto-created for zonal policies
            ;;
    esac

    log "Running terraform init..."
    terraform init -upgrade > "$RESULTS_DIR/storage_init.log" 2>&1 || terraform init > "$RESULTS_DIR/storage_init.log" 2>&1

    # Parallel deployment: storage + client (faster, required for GCP colocation)
    if [ "$SKIP_CLIENT" = "false" ]; then
        log "Parallel deployment: storage + client"

        CLIENT_DIR="$SCRIPT_DIR/$CLOUD/client-testing"
        mkdir -p "$CLIENT_DIR"

        # Prepare client tfvars (all values known upfront)
        case "$CLOUD" in
            gcp)
                REGION=$(echo "$ZONE" | sed 's/-[^-]*$//')
                if [ -z "$CLIENT_MACHINE_TYPE" ]; then
                    STORAGE_VCPUS=$(echo "$RESOLVED_MACHINE_TYPE" | grep -oE '[0-9]+$')
                    CLIENT_VCPUS=$((STORAGE_VCPUS * 2))
                    [ "$CLIENT_VCPUS" -lt 16 ] && CLIENT_VCPUS=16
                    CLIENT_MACHINE_TYPE="n2-highcpu-${CLIENT_VCPUS}"
                fi
                cat > "$CLIENT_DIR/terraform.tfvars" <<EOFCLIENT
project_id = "$PROJECT_ID"
zone = "$ZONE"
client_name = "${DEPLOYMENT_NAME}-client"
machine_type = "$CLIENT_MACHINE_TYPE"
ssh_public_key = "$SSH_PUBLIC_KEY"
use_spot = $USE_SPOT
admin_username = "mayascale"
EOFCLIENT
                [ "$ENABLE_COLOCATION" = "true" ] && echo "placement_policy_name = \"${DEPLOYMENT_NAME}-placement-policy\"" >> "$CLIENT_DIR/terraform.tfvars"
                ;;
            aws)
                # Use specified ZONE or default to us-east-1a for client colocation
                AWS_AZ="${ZONE:-us-east-1a}"
                [ -z "$CLIENT_MACHINE_TYPE" ] && CLIENT_MACHINE_TYPE="c6in.xlarge"
                cat > "$CLIENT_DIR/terraform.tfvars" <<EOFCLIENT
key_pair_name = "$KEY_PAIR_NAME"
client_name = "${DEPLOYMENT_NAME}-client"
ssh_public_key = "$SSH_PUBLIC_KEY"
use_spot = $USE_SPOT
availability_zone = "$AWS_AZ"
admin_username = "mayascale"
instance_type = "$CLIENT_MACHINE_TYPE"
EOFCLIENT
                ;;
            azure)
                if [ -z "$CLIENT_MACHINE_TYPE" ]; then
                    # Extract vCPU count from storage machine type (e.g., Standard_L8s_v3 -> 8)
                    STORAGE_VCPUS=$(echo "$RESOLVED_MACHINE_TYPE" | grep -oE '[0-9]+' | head -1)
                    CLIENT_VCPUS=$((STORAGE_VCPUS * 2))
                    [ "$CLIENT_VCPUS" -lt 16 ] && CLIENT_VCPUS=16
                    CLIENT_MACHINE_TYPE="Standard_D${CLIENT_VCPUS}s_v5"
                fi
                cat > "$CLIENT_DIR/terraform.tfvars" <<EOFCLIENT
subscription_id = "$AZURE_SUB_ID"
resource_group_name = "$RESOURCE_GROUP"
location = "$LOCATION"
client_name = "${DEPLOYMENT_NAME}-client"
ssh_public_key = "$SSH_PUBLIC_KEY"
vnet_name = "vnet-${DEPLOYMENT_NAME}"
subnet_name = "subnet-${DEPLOYMENT_NAME}"
use_spot = $USE_SPOT
admin_username = "mayascale"
vm_size = "$CLIENT_MACHINE_TYPE"
EOFCLIENT
                # Add PPG for zonal deployments (non-regional policies)
                if [[ ! "$POLICY" =~ ^regional- ]]; then
                    PPG_ID="/subscriptions/${AZURE_SUB_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/proximityPlacementGroups/ppg-${DEPLOYMENT_NAME}"
                    echo "proximity_placement_group_id = \"$PPG_ID\"" >> "$CLIENT_DIR/terraform.tfvars"
                fi
                ;;
        esac

        # Init client
        (cd "$CLIENT_DIR" && terraform init -upgrade > "$RESULTS_DIR/client_init.log" 2>&1)

        # Start storage in background
        log "Starting storage deployment (log: $RESULTS_DIR/storage_apply.log)..."
        terraform apply -auto-approve > "$RESULTS_DIR/storage_apply.log" 2>&1 &
        STORAGE_PID=$!

        # GCP colocation: wait for placement policy before starting client
        if [ "$CLOUD" = "gcp" ] && [ "$ENABLE_COLOCATION" = "true" ]; then
            log "Waiting for placement policy..."
            PLACEMENT_POLICY_NAME="${DEPLOYMENT_NAME}-placement-policy"
            for i in {1..12}; do
                gcloud compute resource-policies describe "$PLACEMENT_POLICY_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null && break
                sleep 5
            done
        fi

        # Start client
        log "Starting client deployment (log: $RESULTS_DIR/client_apply.log)..."
        (cd "$CLIENT_DIR" && terraform apply -auto-approve > "$RESULTS_DIR/client_apply.log" 2>&1) &
        CLIENT_PID=$!

        # Wait for both
        log "Waiting for deployments..."
        STORAGE_OK=true && wait $STORAGE_PID || STORAGE_OK=false
        CLIENT_OK=true && wait $CLIENT_PID || CLIENT_OK=false

        [ "$STORAGE_OK" = true ] && success "Storage deployed" || { fail "Storage failed - see $RESULTS_DIR/storage_apply.log"; tail -20 "$RESULTS_DIR/storage_apply.log"; exit 1; }
        [ "$CLIENT_OK" = true ] && success "Client deployed" && CLIENT_DEPLOYED_PARALLEL=true || warn "Client failed - see $RESULTS_DIR/client_apply.log"
    else
        # No client - just deploy storage
        log "Running terraform apply (log: $RESULTS_DIR/storage_apply.log)..."
        if ! terraform_apply_with_retry "$RESULTS_DIR/storage_apply.log"; then
            fail "Terraform apply failed - see $RESULTS_DIR/storage_apply.log"
            tail -20 "$RESULTS_DIR/storage_apply.log"
            exit 1
        fi
        success "Storage deployed"
    fi
fi

# Get storage outputs
log "Reading terraform outputs..."
terraform output -json > "$RESULTS_DIR/storage_outputs.json" 2>&1

get_output() {
    terraform output -raw "$1" 2>/dev/null || echo ""
}

# Standard output names
NODE1_IP=$(get_output node1_public_ip)
NODE1_INTERNAL_IP=$(get_output node1_private_ip)
NODE1_NAME=$(get_output node1_name)
VIP1=$(get_output vip1_address)
VIP2=$(get_output vip2_address)

# Cloud-specific SSH command and placement group info
case "$CLOUD" in
    gcp)
        SSH_BASE="gcloud compute ssh ${SSH_USER}@${NODE1_NAME} --zone=${ZONE} --project=${PROJECT_ID} --quiet --ssh-flag=-o --ssh-flag=StrictHostKeyChecking=no --ssh-flag=-o --ssh-flag=UserKnownHostsFile=/dev/null"
        # Derive placement policy name from deployment name (matches terraform naming)
        if [ "$ENABLE_COLOCATION" = "true" ]; then
            PLACEMENT_POLICY_NAME="${DEPLOYMENT_NAME}-placement-policy"
        else
            PLACEMENT_POLICY_NAME=""
        fi
        ;;
    aws)
        if [ -f "$HOME/.ssh/${KEY_PAIR_NAME}.pem" ]; then
            SSH_BASE="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $HOME/.ssh/${KEY_PAIR_NAME}.pem ${SSH_USER}@${NODE1_IP}"
        else
            SSH_BASE="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${SSH_USER}@${NODE1_IP}"
        fi
        PLACEMENT_GROUP_NAME=$(get_output placement_group_name)
        # Get storage AZ for client colocation
        STORAGE_AZ=$(get_output availability_zone)
        ;;
    azure)
        SSH_BASE="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${SSH_USER}@${NODE1_IP}"
        VNET_NAME=$(get_output virtual_network_name)
        SUBNET_NAME=$(get_output subnet_name)
        AZURE_SUB_ID=$(az account show --query id -o tsv 2>/dev/null || echo "")
        # Get PPG ID from cluster_config output
        PPG_ID=$(terraform output -json cluster_config 2>/dev/null | jq -r '.placement_group_id // empty' 2>/dev/null || echo "")
        ;;
esac

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

# Start client deployment in background (skip if already deployed in parallel for colocation)
CLIENT_DEPLOY_PID=""
CLIENT_REUSED="false"
if [ "$SKIP_CLIENT" = "false" ] && [ "${CLIENT_DEPLOYED_PARALLEL:-false}" != "true" ]; then
    CLIENT_DIR="$SCRIPT_DIR/$CLOUD/client-testing"

    if [ -f "$CLIENT_DIR/terraform.tfstate" ]; then
        log "Existing client found - refreshing in background..."
        (
            cd "$CLIENT_DIR" || exit 1
            terraform apply -auto-approve -refresh=true > "$RESULTS_DIR/client_refresh.log" 2>&1
        ) &
        CLIENT_DEPLOY_PID=$!
        CLIENT_REUSED="true"
    else
        log "Starting client deployment in background..."
        (
            cd "$CLIENT_DIR" || exit 1

            case "$CLOUD" in
                gcp)
                    # Client needs 2x storage vCPUs (2 storage nodes) to drive full performance
                    STORAGE_VCPUS=$(echo "$RESOLVED_MACHINE_TYPE" | grep -oE '[0-9]+$')
                    CLIENT_VCPUS=$((STORAGE_VCPUS * 2))
                    # Minimum 16 vCPUs for decent test coverage
                    [ "$CLIENT_VCPUS" -lt 16 ] && CLIENT_VCPUS=16
                    CLIENT_MACHINE_TYPE="n2-highcpu-${CLIENT_VCPUS}"
                    cat > terraform.tfvars <<EOFCLIENT
project_id = "$PROJECT_ID"
zone = "$ZONE"
client_name = "${DEPLOYMENT_NAME}-client"
machine_type = "$CLIENT_MACHINE_TYPE"
ssh_public_key = "$SSH_PUBLIC_KEY"
use_spot = $USE_SPOT
EOFCLIENT
                    # Join placement policy for colocation
                    if [ -n "$PLACEMENT_POLICY_NAME" ]; then
                        echo "placement_policy_name = \"$PLACEMENT_POLICY_NAME\"" >> terraform.tfvars
                    fi
                    ;;
                aws)
                    cat > terraform.tfvars <<EOFCLIENT
key_pair_name = "$KEY_PAIR_NAME"
client_name = "${DEPLOYMENT_NAME}-client"
ssh_public_key = "$SSH_PUBLIC_KEY"
use_spot = $USE_SPOT
EOFCLIENT
                    # Join placement group for colocation
                    if [ -n "$PLACEMENT_GROUP_NAME" ]; then
                        echo "placement_group_name = \"$PLACEMENT_GROUP_NAME\"" >> terraform.tfvars
                    fi
                    # Must be in same AZ as storage for placement group
                    if [ -n "$STORAGE_AZ" ]; then
                        echo "availability_zone = \"$STORAGE_AZ\"" >> terraform.tfvars
                    fi
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
                    # Join proximity placement group for colocation
                    if [ -n "$PPG_ID" ]; then
                        echo "proximity_placement_group_id = \"$PPG_ID\"" >> terraform.tfvars
                    fi
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
echo " MayaScale Validation"
echo "========================================"
echo " Node1 IP:  $NODE1_IP"
echo " VIP1:      ${VIP1:-N/A}"
echo " VIP2:      ${VIP2:-N/A}"
echo " SSH User:  $SSH_USER"
echo "========================================"
echo ""

# Test 1: SSH connectivity
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

# Test 2: Wait for MayaScale cluster setup
log "Test 2: Waiting for MayaScale cluster setup..."
MAX_WAIT=300
WAIT_INTERVAL=15
ELAPSED=0
CLUSTER_READY=false

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if run_ssh "sudo test -f /opt/mayastor/config/.cluster-configured" >/dev/null 2>&1; then
        CLUSTER_READY=true
        success "MayaScale cluster ready"
        break
    fi
    log "Waiting for cluster setup... (${ELAPSED}s/${MAX_WAIT}s)"
    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [ "$CLUSTER_READY" = false ]; then
    fail "MayaScale cluster setup timed out after ${MAX_WAIT}s"
    echo "Check logs: sudo tail -f /opt/mayastor/logs/mayascale-terraform-startup.log"
    exit 1
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

# Wait for client deployment and run NVMe tests
if [ "$SKIP_CLIENT" = "false" ]; then
    echo ""

    # Get client IP - either from parallel deployment or existing state (reuse)
    CLIENT_DIR="$SCRIPT_DIR/$CLOUD/client-testing"
    if [ "$CLIENT_OK" = "true" ]; then
        # Fresh parallel deployment succeeded
        cd "$CLIENT_DIR"
        CLIENT_IP=$(terraform output -raw client_public_ip 2>/dev/null)
        cd "$TF_DIR"
        log "Client ready: $CLIENT_IP (${CLIENT_MACHINE_TYPE})"
    elif [ -f "$CLIENT_DIR/terraform.tfstate" ]; then
        # Reuse existing client - check if machine type override requested
        CURRENT_MACHINE_TYPE=$(grep -E "machine_type|instance_type|vm_size" "$CLIENT_DIR/terraform.tfvars" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [ -n "$CLIENT_MACHINE_TYPE" ] && [ "$CLIENT_MACHINE_TYPE" != "$CURRENT_MACHINE_TYPE" ]; then
            log "Resizing client from $CURRENT_MACHINE_TYPE to $CLIENT_MACHINE_TYPE..."
            # Update tfvars with new machine type
            case "$CLOUD" in
                gcp) sed -i "s/machine_type = .*/machine_type = \"$CLIENT_MACHINE_TYPE\"/" "$CLIENT_DIR/terraform.tfvars" ;;
                aws) sed -i "s/instance_type = .*/instance_type = \"$CLIENT_MACHINE_TYPE\"/" "$CLIENT_DIR/terraform.tfvars" ;;
                azure) sed -i "s/vm_size = .*/vm_size = \"$CLIENT_MACHINE_TYPE\"/" "$CLIENT_DIR/terraform.tfvars" ;;
            esac
            (cd "$CLIENT_DIR" && terraform apply -auto-approve > "$RESULTS_DIR/client_resize.log" 2>&1) || warn "Client resize failed - see $RESULTS_DIR/client_resize.log"
        elif [ -z "$CLIENT_MACHINE_TYPE" ]; then
            CLIENT_MACHINE_TYPE="$CURRENT_MACHINE_TYPE"
        fi
        cd "$CLIENT_DIR"
        CLIENT_IP=$(terraform output -raw client_public_ip 2>/dev/null)
        cd "$TF_DIR"
        if [ -n "$CLIENT_IP" ] && [ "$CLIENT_IP" != "null" ]; then
            log "Reusing client: $CLIENT_IP (${CLIENT_MACHINE_TYPE:-unknown})"
        else
            warn "Client state exists but no IP - skipping NVMe tests"
            CLIENT_IP=""
        fi
    else
        warn "No client deployed - skipping NVMe tests"
        CLIENT_IP=""
    fi

    if [ -n "$CLIENT_IP" ]; then
        # Set up client SSH based on cloud provider
        CLIENT_NAME=$(cd "$CLIENT_DIR" && terraform output -raw client_name 2>/dev/null || echo "")
        CLIENT_SSH_USER=$(cd "$CLIENT_DIR" && terraform output -raw ssh_user 2>/dev/null || echo "mayanas")
        if [ -z "$CLIENT_SSH_USER" ]; then
            warn "Could not get ssh_user from terraform output"
            CLIENT_SSH_USER="ubuntu"  # safe fallback for most cloud images
        fi
        case "$CLOUD" in
            gcp)
                CLIENT_SSH_BASE="gcloud compute ssh ${CLIENT_SSH_USER}@${CLIENT_NAME} --zone=${ZONE} --project=${PROJECT_ID} --quiet --ssh-flag=-o --ssh-flag=StrictHostKeyChecking=no --ssh-flag=-o --ssh-flag=UserKnownHostsFile=/dev/null --ssh-flag=-o --ssh-flag=LogLevel=ERROR"
                ;;
            aws)
                if [ -f "$HOME/.ssh/${KEY_PAIR_NAME}.pem" ]; then
                    CLIENT_SSH_BASE="ssh -i $HOME/.ssh/${KEY_PAIR_NAME}.pem -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 ${CLIENT_SSH_USER}@${CLIENT_IP}"
                else
                    CLIENT_SSH_BASE="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 ${CLIENT_SSH_USER}@${CLIENT_IP}"
                fi
                ;;
            azure)
                CLIENT_SSH_BASE="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 ${CLIENT_SSH_USER}@${CLIENT_IP}"
                ;;
        esac

        # Client SSH helper function
        run_client_ssh() {
            if [ "$CLOUD" = "gcp" ]; then
                $CLIENT_SSH_BASE --command "$1"
            else
                $CLIENT_SSH_BASE "$1"
            fi
        }

        # Client SCP helper function (files go to user's home directory)
        copy_to_client() {
            local src="$1"
            local dst="$2"
            case "$CLOUD" in
                gcp)
                    gcloud compute scp "$src" "${CLIENT_SSH_USER}@${CLIENT_NAME}:~/${dst}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
                    ;;
                aws)
                    if [ -f "$HOME/.ssh/${KEY_PAIR_NAME}.pem" ]; then
                        scp -i "$HOME/.ssh/${KEY_PAIR_NAME}.pem" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$src" "${CLIENT_SSH_USER}@${CLIENT_IP}:~/${dst}"
                    else
                        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$src" "${CLIENT_SSH_USER}@${CLIENT_IP}:~/${dst}"
                    fi
                    ;;
                azure)
                    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$src" "${CLIENT_SSH_USER}@${CLIENT_IP}:~/${dst}"
                    ;;
            esac
        }

        # Test 3: Connect NVMe volumes on client
        log "Test 3: Connecting NVMe volumes..."
        CONNECT_SCRIPT="$SCRIPT_DIR/connect_volumes.sh"
        CLIENT_VOLUMES=$(terraform output -json client_volumes 2>/dev/null || echo "{}")

        # Create storage config for client (connect_volumes.sh expects $HOME/storage_config.json)
        cat > /tmp/storage_config.json << EOF
{
  "primary_vip": "${VIP1:-$NODE1_INTERNAL_IP}",
  "secondary_vip": "${VIP2:-$NODE1_INTERNAL_IP}",
  "volumes": $CLIENT_VOLUMES
}
EOF

        # Upload scripts to client home directory
        log "Uploading storage config and connect script to client..."
        copy_to_client /tmp/storage_config.json storage_config.json
        copy_to_client "$CONNECT_SCRIPT" connect_volumes.sh
        run_client_ssh "chmod +x ~/connect_volumes.sh"
        rm /tmp/storage_config.json

        # Connect volumes (script uses sudo internally, don't run as root or $HOME is wrong)
        if run_client_ssh "~/connect_volumes.sh tcp" 2>&1 | tee "$RESULTS_DIR/connect_volumes.log"; then
            success "NVMe volumes connected"
        else
            warn "Volume connection had issues - check $RESULTS_DIR/connect_volumes.log"
        fi

        # Test 4: Run NVMe performance test
        log "Test 4: Running NVMe performance test..."
        FIO_SCRIPT="$SCRIPT_DIR/fio-performance-test.sh"

        if [ -f "$FIO_SCRIPT" ]; then
            # Copy test script to client
            log "Uploading test script to client..."
            copy_to_client "$FIO_SCRIPT" fio-test.sh
            run_client_ssh "chmod +x ~/fio-test.sh"

            # Run NVMe performance test
            log "Testing NVMe storage..."
            echo ""
            run_client_ssh "sudo ~/fio-test.sh --runtime 30" 2>&1 | tee "$RESULTS_DIR/nvme_performance.log"
            echo ""

            if [ ${PIPESTATUS[0]} -eq 0 ]; then
                success "NVMe performance test completed"
            else
                warn "NVMe performance test had errors"
            fi
        else
            warn "FIO test script not found: $FIO_SCRIPT"
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
