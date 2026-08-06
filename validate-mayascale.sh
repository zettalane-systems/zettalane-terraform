#!/bin/bash
# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

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

# The client-testing dir is shared across deploys; a tfstate left from a different
# RG makes terraform refresh a prior cluster's resources. If state has managed
# resources but none in the target RG, move it aside (back up, don't delete).
client_state_guard() {
    local st="$1/terraform.tfstate" rg="$2"
    [ -f "$st" ] || return 0
    if grep -q '/resourceGroups/' "$st" 2>/dev/null && \
       ! grep -qi "/resourceGroups/${rg}/" "$st" 2>/dev/null; then
        local bak="${st}.stale.$(date +%Y%m%d_%H%M%S)"
        warn "Stale client state (no resources in RG '$rg') -> moving aside: $bak"
        mv "$st" "$bak"
        [ -f "${st}.backup" ] && mv "${st}.backup" "${bak}.backup"
    fi
}

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
KEY_PAIR_NAME=""           # derived from --ssh-key basename for AWS
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
ASSIGN_PUBLIC_IP="true"
BUCKET_COUNT="0"   # -b: object buckets per node for the objbacker cold tier (0 = none, azure only)
FSX_MODE="false"   # --fsx [zfs]: ZFS mirror mode (FSx for OpenZFS equivalent)
VG_MODE="false"    # --fsx vg: LVM VG on MD-RAID for Kubernetes CSI (vg-active-active)
CSI_MODE="false"   # --csi [mayanas|mayascale]: stage CSI (csi_backend.json + scripts) regardless of fsx substrate
DEPLOY_TYPE_OVERRIDE="" # --fsx zfs-single|vg-single: single-node deployment_type override (azure only)
CSI_DRIVER="mayascale"  # CSI product when --csi: mayascale=block/zvol, mayanas=file/NFS
# Explicit image handoff (--image-id / --image-project / --image-family). Empty = use the
# cloud's Marketplace listing. Set = a specific image (community edition, or any private
# build): no publisher plan, so the Marketplace plan-terms check is skipped.
IMAGE_ID=""        # azure: full gallery image id  |  aws: AMI id
IMAGE_PROJECT=""   # gcp: source_image_project
IMAGE_FAMILY=""    # gcp: source_image_family
ENABLE_COLOCATION="false" # --colocation: opt-in compact placement group (zonal only); OFF by default (functional tests need no rack locality + avoids placement-policy lifecycle friction)
CLUSTER_SLOT="0"   # --cluster-slot N: deterministic VIP partition (+ Azure backend subnet) for multi-pair in one shared VNet/VPC; 0=standalone (random VIP). All clouds: VIP. Azure also: backend /24.

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
    --zone AZ                 AWS availability zone (optional)
    (AWS EC2 keypair name is derived from --ssh-key basename:
     -k ~/.ssh/mykey.pem  →  key_pair_name = "mykey")

AZURE OPTIONS:
    --resource-group RG       Azure resource group name (required)
    --location LOCATION       Azure location (e.g., eastus, westus)

COMMON OPTIONS:
    -n, --name NAME           Deployment name (default: demo)
    -b, --bucket-count COUNT  Object buckets per node for the objbacker cold tier
			      (default: 0 = no cold tier, max: 4)
    -o, --policy POLICY       Performance policy (default: zonal-standard-performance)
    -m, --machine-type TYPE   Override storage machine type (cloud-specific)
    --client-machine-type TYPE  Override client machine type (cloud-specific)
    -k, --ssh-key PATH        SSH key (REQUIRED). Public key (ssh-rsa/...)
                              or private key (.pem / OpenSSH) — type detected
                              from file content; for private keys the public
                              half is derived in-memory via ssh-keygen.
    --spot                    Use spot/preemptible instances (default: on-demand)
    --fsx [zfs|vg]            Storage architecture (default = MD-RAID block, active-active):
                              zfs (or bare --fsx) = ZFS mirror (FSx for OpenZFS equivalent);
                              vg = LVM VG on MD-RAID for Kubernetes CSI (vg-active-active, GCP)
    --no-public-ip            Deploy storage nodes with no public IPs.
                              Auto-enables Private Google Access on the
                              subnet (GCP) and IAP tunnel for SSH.
                              (default: public IPs ON for direct SSH)
    --skip-deploy             Skip terraform apply, validate existing deployment
    --skip-client             Skip client deployment, storage-only validation.
                              With -d/--destroy: preserve the client VM (and its
                              state) while destroying storage -- reuse it across a
                              storage redeploy.
    --csi [mayanas|mayascale] Stage CSI inputs (csi_backend.json + test scripts) to the
                              client and skip the legacy connect+fio test. Product:
                              mayascale=block/zvol (default), mayanas=file/NFS. If no
                              --fsx is given, the substrate is auto-selected to one the
                              driver can provision: mayascale -> vg (vg-active-active),
                              mayanas -> zfs (zfs-active-active). An explicit --fsx zfs|vg
                              overrides (e.g. --fsx zfs for block zvols on a zpool); add
                              --skip-deploy to stage onto a live cluster.
    --colocation              Opt in to a compact placement group (nodes+client co-located;
                              zonal policies only). OFF by default -- functional tests need
                              no rack locality, and skipping it avoids the placement-policy
                              destroy-in-use / re-create-409 friction.
    -d, --destroy             Destroy all resources and exit
    -h, --help                Show this help

PERFORMANCE POLICIES:
    zonal-*     Single availability zone (lower latency, no cross-zone replication)
    regional-*  Cross-zone HA (higher durability, ~10-17% write overhead)

    Policy                      GCP             AWS             Azure           Write IOPS   Read IOPS
    zonal-standard-performance  n2-highcpu-8    i3en.2xlarge    L4aos_v4        100-140K     340-380K
    zonal-medium-performance    n2-highcpu-16   i3en.xlarge     L8aos_v4        175-288K     650-720K
    zonal-high-performance      n2-highcpu-32   i3en.6xlarge    L24aos_v4       290-864K     900K-2.16M
    zonal-ultra-performance     n2-highcpu-64   i3en.12xlarge   L32aos_v4       585K-1.15M   1.13M-2.88M

EXAMPLES:
    # GCP with medium performance
    $0 --cloud gcp --project-id my-project --zone us-central1-a

    # AWS with high performance (keypair name = "my-keypair")
    $0 --cloud aws -k ~/.ssh/my-keypair.pem -o zonal-high-performance

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
        --bucket-count|-b)
            BUCKET_COUNT="$2"
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
        --ssh-key|-k)
            SSH_PUBLIC_KEY_FILE="$2"
            shift 2
            ;;
        --spot)
            USE_SPOT="true"
            shift
            ;;
        --no-public-ip)
            ASSIGN_PUBLIC_IP="false"
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
        --csi)
            CSI_MODE="true"
            case "${2:-}" in
                mayanas|mayascale) CSI_DRIVER="$2"; shift 2 ;;
                ""|-*)             shift ;;   # no product arg -> default CSI_DRIVER
                *) echo "ERROR: --csi takes 'mayanas' or 'mayascale' (got '$2')"; usage ;;
            esac
            ;;
        --colocation)
            ENABLE_COLOCATION="true"   # opt-in compact placement group (zonal only)
            shift
            ;;
        --image-id)
            # Explicit image, bypassing the Marketplace listing: Azure = full gallery
            # image id, AWS = AMI id. A custom/community image carries no publisher
            # plan, so the plan-terms check below is skipped when this is set.
            IMAGE_ID="$2"; shift 2
            ;;
        --image-project)
            IMAGE_PROJECT="$2"; shift 2      # GCP: source_image_project
            ;;
        --image-family)
            IMAGE_FAMILY="$2"; shift 2       # GCP: source_image_family
            ;;
        --dev)
            # Shorthand for an internal build -- one flag, any cloud. The value's shape
            # says which: an /subscriptions/... path is an Azure gallery image id,
            # ami-* is an AWS AMI, project/family is GCP. Replaces patching this script.
            #   --dev /subscriptions/.../galleries/zettalaneDev/images/mayascale19/versions/latest
            #   --dev zettalane-dev/mayascale-devel
            #   --dev ami-0996832d09c19fc85
            case "$2" in
                /*)            IMAGE_ID="$2" ;;
                ami-*)         IMAGE_ID="$2" ;;
                */*)           IMAGE_PROJECT="${2%%/*}"; IMAGE_FAMILY="${2#*/}" ;;
                *)  echo "ERROR: --dev wants an azure image id (/subscriptions/...), an AWS ami-*, or gcp <project>/<family> (got '$2')"; usage ;;
            esac
            shift 2
            ;;
        -d|--destroy)
            DESTROY_MODE="true"
            shift
            ;;
        --fsx)
            # Optional mode arg: "vg" -> LVM VG on MD-RAID for Kubernetes CSI (vg-active-active,
            # GCP); "zfs" or bare --fsx -> ZFS mirror (FSx for OpenZFS equivalent).
            case "${2:-}" in
                vg)  VG_MODE="true";  shift 2 ;;
                zfs) FSX_MODE="true"; shift 2 ;;
                zfs-single) FSX_MODE="true"; DEPLOY_TYPE_OVERRIDE="zfs-single"; shift 2 ;;
                vg-single)  VG_MODE="true";  DEPLOY_TYPE_OVERRIDE="vg-single";  shift 2 ;;
                ""|--*) FSX_MODE="true"; shift ;;
                *) fail "--fsx takes 'zfs', 'vg', 'zfs-single', or 'vg-single' (got '$2')"; usage ;;
            esac
            ;;
        --cluster-slot)
            CLUSTER_SLOT="$2"; shift 2
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

if [[ ! "$BUCKET_COUNT" =~ ^[0-4]$ ]]; then
    fail "--bucket-count must be between 0 and 4 (0 = no object cold tier)"
fi

# The objbacker cold tier: azure + gcp + aws mayascale provision buckets.
if [ "$BUCKET_COUNT" -gt 0 ] && [ "$CLOUD" != "azure" ] && [ "$CLOUD" != "gcp" ] && [ "$CLOUD" != "aws" ]; then
    fail "--bucket-count is only supported on azure/gcp/aws (got: $CLOUD)"
fi

# Single-node (zfs-single / vg-single): azure + gcp + aws mayascale.
if [ -n "$DEPLOY_TYPE_OVERRIDE" ] && [ "$CLOUD" != "azure" ] && [ "$CLOUD" != "gcp" ] && [ "$CLOUD" != "aws" ]; then
    fail "--fsx $DEPLOY_TYPE_OVERRIDE (single-node) is only supported on azure/gcp/aws (got: $CLOUD)"
fi

# CSI needs a provisionable substrate. The default (active-active = MD-RAID block whose
# auto-exported data-node-X are V_RG) exposes NO pool the CSI driver can carve from, so
# --csi without an explicit --fsx would deploy a cluster the driver can't provision against.
# Auto-select the substrate that matches the CSI product: mayascale (block) -> vg-active-active
# (per-node CSI VGs the driver carves LVs from); mayanas (file/NFS) -> zfs-active-active
# (zpool NFS exports). An explicit --fsx zfs|vg is always honored as-is.
if [ "$CSI_MODE" = "true" ] && [ "$VG_MODE" != "true" ] && [ "$FSX_MODE" != "true" ]; then
    if [ "$CSI_DRIVER" = "mayascale" ]; then
        VG_MODE="true"
        warn "--csi $CSI_DRIVER without --fsx: defaulting substrate to vg-active-active (LVM VG for block CSI). Pass --fsx zfs to override (block zvols on a ZFS pool)."
    else
        FSX_MODE="true"
        warn "--csi $CSI_DRIVER without --fsx: defaulting substrate to zfs-active-active (ZFS pool for file/NFS CSI)."
    fi
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

        # GCP pre-flight: Compute Engine API must be enabled (otherwise
        # terraform fails 5 minutes in). Marketplace agreement acceptance
        # for VM products is UI-only on GCP — no public API to query or
        # accept programmatically — so we just print a heads-up.
        if ! gcloud services list --enabled --project="$PROJECT_ID" \
                --filter='config.name=compute.googleapis.com' \
                --format='value(name)' 2>/dev/null | grep -q compute; then
            echo
            echo "ERROR: Compute Engine API not enabled in project $PROJECT_ID"
            echo
            echo "Enable with:"
            echo "  gcloud services enable compute.googleapis.com --project=$PROJECT_ID"
            echo "Or via Console:"
            echo "  https://console.cloud.google.com/apis/library/compute.googleapis.com?project=$PROJECT_ID"
            exit 1
        fi
        ;;
    aws)
        TF_DIR="$SCRIPT_DIR/aws/mayascale"
        SSH_USER="ec2-user"
        RESOLVED_MACHINE_TYPE="${MACHINE_TYPE:-${AWS_POLICIES[$POLICY]}}"

        # AWS Marketplace pre-flight: confirm the customer's account has
        # subscribed to MayaScale. Without subscription, the data.aws_ami
        # lookup in aws/mayascale/main.tf returns empty and terraform fails
        # with "OptInRequired" — gate it here with a clearer message.
        # Product code matches aws/mayascale/variables.tf:mayascale_product_code.
        # Skip the check if the variable still holds the placeholder (means
        # MayaScale isn't published to AWS Marketplace yet).
        MAYASCALE_PRODUCT_CODE="9jnrdw5qr5p4m6pp1s57np4em"
        if [ "$MAYASCALE_PRODUCT_CODE" = "PLACEHOLDER_MAYASCALE_PRODUCT_CODE" ]; then
            echo "WARN: MayaScale isn't published on AWS Marketplace yet"
            echo "      (mayascale_product_code is still a placeholder in"
            echo "       aws/mayascale/variables.tf). data.aws_ami will return"
            echo "       empty unless you set ami_id explicitly. Continuing anyway."
        else
            AWS_REGION_FOR_CHECK=$(aws configure get region 2>/dev/null || echo "us-east-1")
            # Not on destroy: this one EXITS rather than prompting, so an unsubscribed
            # (or since-unsubscribed) account could not tear down what it deployed.
            if [ "$DESTROY_MODE" != "true" ] \
                && ! aws ec2 describe-images --region "$AWS_REGION_FOR_CHECK" \
                    --owners aws-marketplace \
                    --filters "Name=product-code,Values=$MAYASCALE_PRODUCT_CODE" \
                    --query 'Images[0].ImageId' --output text 2>/dev/null \
                    | grep -q '^ami-'; then
                echo
                echo "ERROR: AWS Marketplace subscription required for MayaScale"
                echo
                echo "Your AWS account ($(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo unknown))"
                echo "in region $AWS_REGION_FOR_CHECK does not have MayaScale subscribed yet."
                echo
                echo "To subscribe (one-time, per AWS account):"
                echo "  1. Visit https://aws.amazon.com/marketplace and search for MayaScale / ZettaLane"
                echo "  2. Click 'Continue to Subscribe' → 'Accept Terms'"
                echo "  3. Wait ~1-2 minutes for the subscription to propagate"
                echo "  4. Re-run this script"
                echo
                echo "Without this, terraform apply will fail with 'OptInRequired'."
                exit 1
            fi
        fi
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

        # Azure Marketplace pre-flight: the module's default falls to the
        # plan-bound mayascale-cloud-ent listing (azure/mayascale/main.tf:
        # 742-758). Customer's subscription must accept plan terms or
        # terraform apply fails with "Marketplace purchase eligibility check
        # returned errors". Hard-coded to match the module's
        # source_image_reference + plan block.
        # Skipped when an explicit image is handed in (--image-id: community edition,
        # a dev build, any private gallery image). Those don't go through Marketplace
        # and carry no publisher plan, so terms acceptance is moot.
        AZURE_PLAN_PUB="zettalane_systems-5254599"
        AZURE_PLAN_OFFER="mayascale-cloud-ent"
        AZURE_PLAN_NAME="mayascale-cloud-ent"
        if [ "$DESTROY_MODE" = "true" ]; then
            # Destroy provisions no VM, so no plan is ever purchased. Callers also stop
            # passing --image-id on teardown (deploy-zettabranch.sh does), which used to
            # drop us into the check below and prompt for the PAID plan's terms while
            # tearing down a community-gallery deployment that never used it.
            log "--destroy: nothing is provisioned — skipping Marketplace plan-terms check"
            ACCEPTED="True"
        elif [ -n "$IMAGE_ID" ]; then
            log "Explicit image (no publisher plan) — skipping Marketplace plan-terms check"
            ACCEPTED="True"
        else
            AZURE_SUB_ID_CHECK="${PROJECT_ID:-$(az account show --query id -o tsv 2>/dev/null || echo "")}"
            ACCEPTED=$(az vm image terms show \
                --publisher "$AZURE_PLAN_PUB" --offer "$AZURE_PLAN_OFFER" --plan "$AZURE_PLAN_NAME" \
                ${AZURE_SUB_ID_CHECK:+--subscription "$AZURE_SUB_ID_CHECK"} \
                --query 'accepted' -o tsv 2>/dev/null || echo "false")
        fi
        if [ "$ACCEPTED" != "True" ]; then
            echo
            echo "Azure Marketplace plan terms have not been accepted in this subscription."
            echo
            echo "  Subscription: ${AZURE_SUB_ID_CHECK:-active}"
            echo "  Plan:         $AZURE_PLAN_PUB / $AZURE_PLAN_OFFER / $AZURE_PLAN_NAME"
            echo
            echo "Accepting the plan terms is a one-time per-subscription step. Without it,"
            echo "terraform apply will fail with 'Marketplace purchase eligibility check returned errors'."
            echo
            read -r -p "Accept terms now? [y/N] " ACCEPT_REPLY
            case "$ACCEPT_REPLY" in
                [yY]|[yY][eE][sS])
                    echo "Running: az vm image terms accept ..."
                    if ! az vm image terms accept \
                            --publisher "$AZURE_PLAN_PUB" \
                            --offer "$AZURE_PLAN_OFFER" \
                            --plan "$AZURE_PLAN_NAME" \
                            ${AZURE_SUB_ID_CHECK:+--subscription "$AZURE_SUB_ID_CHECK"} \
                            >/dev/null; then
                        fail "az vm image terms accept failed — check Azure CLI auth + permissions"
                    fi
                    echo "✓ Terms accepted. Continuing."
                    ;;
                *)
                    fail "Terms not accepted — exiting. Re-run after accepting via:
       az vm image terms accept --publisher $AZURE_PLAN_PUB \\
           --offer $AZURE_PLAN_OFFER --plan $AZURE_PLAN_NAME"
                    ;;
            esac
        fi
        ;;
    *)
        fail "Unknown cloud provider: $CLOUD (use gcp, aws, or azure)"
        exit 1
        ;;
esac

# Resolve --ssh-key into the public-key string. Mandatory. Auto-detects
# whether the file is a public key (ssh-* / ecdsa-*) or a private key
# (-----BEGIN ... PRIVATE KEY-----); for private keys the public half is
# derived in-memory via ssh-keygen -y. SSH_PRIVKEY is set when the input
# was a private key, used later for ssh -i $SSH_PRIVKEY.
if [ -z "${SSH_PUBLIC_KEY_FILE:-}" ]; then
    cat >&2 <<EOF
ERROR: -k | --ssh-key <path> is required.

Pass any of:
  Public key (ssh-rsa / ssh-ed25519 / ssh-ecdsa-*) — VM is created with it
  Private key (.pem / OpenSSH BEGIN ... PRIVATE KEY) — pubkey is derived
                                                      via ssh-keygen -y

Cloud notes:
  GCP, Azure  -k <any pub or pem you control>
              (on GCP, ~/.ssh/google_compute_engine often already exists —
               gcloud auto-creates it on first \`gcloud compute ssh\`)
  AWS         -k <your-ec2-keypair>.pem
              (the keypair must already exist in EC2; its name is derived
              from the .pem basename — ~/.ssh/foo.pem → key_pair_name "foo")
EOF
    exit 1
fi
[ -r "$SSH_PUBLIC_KEY_FILE" ] || { fail "--ssh-key: cannot read $SSH_PUBLIC_KEY_FILE"; exit 1; }
SSH_PRIVKEY=""
# Use ssh-keygen as the authority on whether this is a private key — handles
# RSA/OpenSSH/PKCS8 formats, with or without trailing CRLF / BOM.
if SSH_PUBLIC_KEY=$(ssh-keygen -y -f "$SSH_PUBLIC_KEY_FILE" 2>/dev/null); then
    SSH_PRIVKEY="$SSH_PUBLIC_KEY_FILE"
else
    SSH_KEY_TYPE=$(awk 'NR==1{print $1; exit}' "$SSH_PUBLIC_KEY_FILE")
    case "$SSH_KEY_TYPE" in
        ssh-rsa|ssh-ed25519|ssh-dss|ssh-ecdsa-*|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-*)
            SSH_PUBLIC_KEY=$(cat "$SSH_PUBLIC_KEY_FILE")
            ;;
        *)
            fail "--ssh-key: $SSH_PUBLIC_KEY_FILE is not a recognized SSH key file (first token: '$SSH_KEY_TYPE')"
            exit 1
            ;;
    esac
fi
[ -n "$SSH_PUBLIC_KEY" ] || { fail "--ssh-key: derived empty public key from $SSH_PUBLIC_KEY_FILE"; exit 1; }

# AWS terraform module needs an existing EC2 keypair name (aws_instance.key_name).
# Derive it from the private-key basename (e.g. ~/.ssh/mykey.pem → "mykey")
# so the user just points -k at the .pem they got when creating the keypair.
if [ "$CLOUD" = "aws" ]; then
    [ -n "$SSH_PRIVKEY" ] \
        || { fail "AWS requires --ssh-key to be the .pem private key file (so the EC2 keypair name can be derived from its basename)"; exit 1; }
    KEY_PAIR_NAME=$(basename "$SSH_PRIVKEY")
    KEY_PAIR_NAME="${KEY_PAIR_NAME%.pem}"
    KEY_PAIR_NAME="${KEY_PAIR_NAME%.PEM}"
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

    # Destroy client first -- unless --skip-client, which preserves the client VM
    # (and its tfstate) so it can be reused across a storage redeploy.
    CLIENT_DIR="$SCRIPT_DIR/$CLOUD/client-testing"
    CLIENT_DESTROY_OK=false
    if [ "$SKIP_CLIENT" = "true" ]; then
        log "Skipping client destroy (--skip-client) - keeping client VM and its state"
    elif [ -d "$CLIENT_DIR" ] && [ -f "$CLIENT_DIR/terraform.tfstate" ]; then
        log "Destroying client (log: $RESULTS_DIR/client_destroy.log)..."
        cd "$CLIENT_DIR"
        if terraform destroy -auto-approve -input=false > "$RESULTS_DIR/client_destroy.log" 2>&1; then
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
        # If terraform.tfvars is gone, a bare destroy prompts for the no-default
        # required vars (subscription_id, cluster_name) and fails (stdin redirected).
        # Source subscription_id from the STATE being destroyed -- authoritative,
        # it's in every resource id -- and pass a placeholder cluster_name (its value
        # is cosmetic on destroy; resources are matched by state id, not by name).
        # (The empty-ssh_public_key validation that also blocked this is handled by
        # the non-empty placeholder fallback in azure/mayascale main.tf.)
        STORAGE_DESTROY_VARS=()
        if [ ! -f terraform.tfvars ] && [ "$CLOUD" = "azure" ]; then
            SUB_FROM_STATE=$(grep -oE '/subscriptions/[0-9a-fA-F-]{36}' terraform.tfstate 2>/dev/null | head -1 | grep -oE '[0-9a-fA-F-]{36}')
            SUB_FROM_STATE="${SUB_FROM_STATE:-${PROJECT_ID:-$(az account show --query id -o tsv 2>/dev/null || echo "")}}"
            STORAGE_DESTROY_VARS=(-var "subscription_id=$SUB_FROM_STATE" -var "cluster_name=destroy")
            warn "terraform.tfvars missing - destroying off state (subscription_id=$SUB_FROM_STATE from tfstate)"
        fi
        # --skip-client keeps the client VM, which SHARES the PPG + frontend
        # vnet/subnet that this storage deployment created and owns in state.
        # Drop those three from state before destroy so terraform leaves them
        # for the client instead of failing on them (PPG 409 "still contains
        # VMs" / subnet 400 "in use by <cluster>-client-nic"). They remain in
        # Azure; the next deploy's use-existing guards (ppg_exists / vnet_exists
        # / subnet_exists) re-adopt them. The backend subnet is storage-only and
        # is intentionally left to be destroyed. No-op if this deployment reused
        # pre-existing shared resources (count=0, not in state).
        if [ "$SKIP_CLIENT" = "true" ] && [ "$CLOUD" = "azure" ]; then
            for addr in \
                'azurerm_proximity_placement_group.mayascale[0]' \
                'azurerm_subnet.mayascale[0]' \
                'azurerm_virtual_network.mayascale[0]'; do
                if terraform state rm "$addr" >/dev/null 2>&1; then
                    log "Preserving shared $addr for client (--skip-client)"
                fi
            done
        fi
        if terraform destroy -auto-approve -input=false "${STORAGE_DESTROY_VARS[@]}" > "$RESULTS_DIR/storage_destroy.log" 2>&1; then
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
                # When --skip-client, exclude client-named resources from the orphan
                # sweep so the preserved client VM (and its SA/firewall) survive. Storage
                # + backend resources (nodes, backend net/subnet) are NOT client-named, so
                # they still get swept. (The client lives on the default VPC, never a
                # ${DEPLOYMENT_NAME}-named subnet, so deleting backend net/subnet is safe.)
                CLIENT_EXCL=""; CLIENT_EXCL_SA=""
                if [ "$SKIP_CLIENT" = "true" ]; then
                    CLIENT_EXCL=" AND NOT name~client"
                    CLIENT_EXCL_SA=" AND NOT email~client"
                    log "Preserving client-named resources in orphan sweep (--skip-client)"
                fi
                # Delete any leftover resources with deployment prefix
                for type in instances firewall-rules; do
                    gcloud compute $type list --filter="name~^${DEPLOYMENT_NAME}${CLIENT_EXCL}" --format="value(name)" --project="$PROJECT_ID" 2>/dev/null | while read -r name; do
                        [ -n "$name" ] && log "Deleting orphaned $type: $name" && gcloud compute $type delete "$name" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                    done
                done
                # Subnets need region
                gcloud compute networks subnets list --filter="name~^${DEPLOYMENT_NAME}${CLIENT_EXCL}" --format="value(name,region)" --project="$PROJECT_ID" 2>/dev/null | while read -r name region; do
                    [ -n "$name" ] && log "Deleting orphaned subnet: $name" && gcloud compute networks subnets delete "$name" --region="$region" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                done
                # Networks
                gcloud compute networks list --filter="name~^${DEPLOYMENT_NAME}${CLIENT_EXCL}" --format="value(name)" --project="$PROJECT_ID" 2>/dev/null | while read -r name; do
                    [ -n "$name" ] && log "Deleting orphaned network: $name" && gcloud compute networks delete "$name" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                done
                # Placement policies need region
                gcloud compute resource-policies list --filter="name~^${DEPLOYMENT_NAME}${CLIENT_EXCL}" --format="value(name,region)" --project="$PROJECT_ID" 2>/dev/null | while read -r name region; do
                    [ -n "$name" ] && log "Deleting orphaned policy: $name" && gcloud compute resource-policies delete "$name" --region="$region" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                done
                # Service accounts
                gcloud iam service-accounts list --filter="email~^${DEPLOYMENT_NAME}${CLIENT_EXCL_SA}" --format="value(email)" --project="$PROJECT_ID" 2>/dev/null | while read -r email; do
                    [ -n "$email" ] && log "Deleting orphaned SA: $email" && gcloud iam service-accounts delete "$email" --project="$PROJECT_ID" --quiet 2>/dev/null || true
                done
                ;;
            azure)
                # terraform treats the RG as data and never deletes it, so a fresh
                # single-purpose RG would be orphaned. Reclaim it ONLY if the harness
                # created it (created-by tag) AND it is now empty. A pre-existing/
                # shared (untagged) or still-populated RG is left untouched.
                if [ -n "$RESOURCE_GROUP" ]; then
                    SUB_ID="${PROJECT_ID:-$(az account show --query id -o tsv 2>/dev/null)}"
                    RG_OWNED=$(az group show --subscription "$SUB_ID" -n "$RESOURCE_GROUP" --query "tags.\"created-by\"" -o tsv 2>/dev/null)
                    if [ "$RG_OWNED" = "mayascale-validate" ]; then
                        RG_LEFT=$(az resource list --subscription "$SUB_ID" -g "$RESOURCE_GROUP" --query "length(@)" -o tsv 2>/dev/null)
                        if [ "$RG_LEFT" = "0" ]; then
                            log "Reclaiming harness-created RG '$RESOURCE_GROUP' (tagged, empty)..."
                            az group delete --subscription "$SUB_ID" -n "$RESOURCE_GROUP" --yes -o none 2>/dev/null || true
                        else
                            log "RG '$RESOURCE_GROUP' still has $RG_LEFT resource(s) - leaving it"
                        fi
                    fi
                fi
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
    azure)
        SUB_ID_FOR_DISPLAY="${PROJECT_ID:-$(az account show --query id -o tsv 2>/dev/null)}"
        SUB_NAME_FOR_DISPLAY=$(az account list --query "[?id=='$SUB_ID_FOR_DISPLAY'].name | [0]" -o tsv 2>/dev/null || echo "")
        echo " Subscription: ${SUB_NAME_FOR_DISPLAY:-unknown} ($SUB_ID_FOR_DISPLAY)"
        ;;
esac
echo " Policy:       $POLICY"
echo " Machine Type: $RESOLVED_MACHINE_TYPE"
echo " Spot:         $USE_SPOT"

# Colocation (compact placement group) is opt-in via --colocation (sets ENABLE_COLOCATION),
# and only valid for zonal policies. OFF by default: functional tests need no rack locality,
# and skipping it avoids the placement-policy lifecycle friction (destroy-in-use / re-create
# 409 with a kept client).
if [ "$ENABLE_COLOCATION" = "true" ]; then
    if [[ "$POLICY" =~ ^zonal ]]; then
        echo " Colocation:   enabled (--colocation)"
        if [ "$USE_SPOT" = "true" ]; then
            warn "Spot + colocation may fail if capacity unavailable. Retry without --spot if needed."
        fi
    else
        warn "--colocation ignored: requires a zonal performance policy (got '$POLICY')"
        ENABLE_COLOCATION="false"
    fi
fi
echo "========================================"
echo ""

# When --skip-client preserves the client, it holds the shared compact placement
# policy open (client_count reserves a slot for it), so the policy survives a storage
# destroy. A later storage apply would then 409 trying to CREATE the same-named policy.
# If it already exists in GCP but isn't in state, import it so apply ADOPTS it (the
# new nodes colocate with the preserved client). No-op unless GCP + --skip-client +
# zonal colocation, and only when the policy actually pre-exists.
adopt_placement_policy() {
    [ "$CLOUD" = "gcp" ] && [ "$SKIP_CLIENT" = "true" ] && [ "$ENABLE_COLOCATION" = "true" ] || return 0
    local region name addr id
    region=$(echo "$ZONE" | sed 's/-[^-]*$//')
    name="${DEPLOYMENT_NAME}-placement-policy"
    addr='google_compute_resource_policy.mayascale_placement_policy[0]'
    id="projects/${PROJECT_ID}/regions/${region}/resourcePolicies/${name}"
    terraform state list 2>/dev/null | grep -qxF "$addr" && return 0        # already tracked
    gcloud compute resource-policies describe "$name" --region="$region" --project="$PROJECT_ID" &>/dev/null || return 0  # not present -> normal create
    log "Adopting pre-existing placement policy '$name' into state (--skip-client)..."
    if terraform import "$addr" "$id" >> "$RESULTS_DIR/storage_import.log" 2>&1; then
        success "Imported placement policy '$name' (adopt instead of recreate)"
    else
        warn "Import of '$name' failed - apply may 409; see $RESULTS_DIR/storage_import.log"
    fi
}

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
        adopt_placement_policy
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
deployment_type = "${DEPLOY_TYPE_OVERRIDE:-$([ "$VG_MODE" = "true" ] && echo "vg-active-active" || ([ "$FSX_MODE" = "true" ] && echo "zfs-active-active" || echo "active-active"))}"
zone = "$ZONE"
machine_type = "$RESOLVED_MACHINE_TYPE"
use_spot_vms = $USE_SPOT
assign_public_ip = $ASSIGN_PUBLIC_IP
cluster_slot = $CLUSTER_SLOT
bucket_count = $BUCKET_COUNT
force_destroy_buckets = true
mayascale_startup_wait=15
enable_colocation = $ENABLE_COLOCATION
$([ -n "$IMAGE_PROJECT" ] && echo "source_image_project = \"$IMAGE_PROJECT\"")
$([ -n "$IMAGE_FAMILY" ]  && echo "source_image_family = \"$IMAGE_FAMILY\"")
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
deployment_type = "${DEPLOY_TYPE_OVERRIDE:-$([ "$VG_MODE" = "true" ] && echo "vg-active-active" || ([ "$FSX_MODE" = "true" ] && echo "zfs-active-active" || echo "active-active"))}"
cluster_slot = $CLUSTER_SLOT
instance_type_override = "$RESOLVED_MACHINE_TYPE"
use_spot_instances = $USE_SPOT
bucket_count = $BUCKET_COUNT
force_destroy_buckets = true
assign_public_ip = $ASSIGN_PUBLIC_IP
ssh_cidr_blocks = ["0.0.0.0/0"]
availability_zone = "$AWS_AZ"
$([ -n "$IMAGE_ID" ] && echo "ami_id = \"$IMAGE_ID\"")
EOF
            # AWS placement group auto-created for zonal non-spot
            ;;
        azure)
            AZURE_SUB_ID="${PROJECT_ID:-$(az account show --query id -o tsv 2>/dev/null || echo "")}"
            cat > terraform.tfvars <<EOF
subscription_id = "$AZURE_SUB_ID"
cluster_name = "$DEPLOYMENT_NAME"
location = "$LOCATION"
performance_policy = "$POLICY"
deployment_type = "${DEPLOY_TYPE_OVERRIDE:-$([ "$VG_MODE" = "true" ] && echo "vg-active-active" || ([ "$FSX_MODE" = "true" ] && echo "zfs-active-active" || echo "active-active"))}"
cluster_slot = $CLUSTER_SLOT
bucket_count = $BUCKET_COUNT
use_spot_instances = $USE_SPOT
assign_public_ip = $ASSIGN_PUBLIC_IP
$([ -n "$SSH_PUBLIC_KEY" ] && echo "ssh_public_key = \"$SSH_PUBLIC_KEY\"")
mayascale_startup_wait= 10
$([ -n "$IMAGE_ID" ] && echo "vm_image_id=\"$IMAGE_ID\"")
EOF
            if [ -n "$RESOURCE_GROUP" ]; then
                echo "resource_group_name = \"$RESOURCE_GROUP\"" >> terraform.tfvars
                # named RG: terraform references it as data, never owns/deletes it.
                # If it doesn't exist yet WE create it and TAG it, so -d can reclaim
                # the otherwise-orphaned fresh RG. A pre-existing (untagged) RG is
                # left untouched on destroy.
                if [ "$(az group exists --subscription "$AZURE_SUB_ID" -n "$RESOURCE_GROUP" 2>/dev/null)" = "false" ]; then
                    az group create --subscription "$AZURE_SUB_ID" -n "$RESOURCE_GROUP" -l "$LOCATION" --tags created-by=mayascale-validate -o none 2>/dev/null || true
                fi
                # An RG's region is fixed at creation; the module derives all placement
                # (and the zone check) from the RG's location, so a reused RG in another
                # region silently overrides -l. Fail loudly so the user picks a fresh RG.
                RG_LOC=$(az group show --subscription "$AZURE_SUB_ID" -n "$RESOURCE_GROUP" --query location -o tsv 2>/dev/null)
                if [ -n "$RG_LOC" ] && [ "$RG_LOC" != "$LOCATION" ]; then
                    fail "Resource group '$RESOURCE_GROUP' is in '$RG_LOC' but you requested -l '$LOCATION'. An RG's region cannot be changed -- use a new -g name (created in '$LOCATION') or set -l '$RG_LOC'."
                    exit 1
                fi
            fi
            # PPG (proximity placement group) is OPT-IN -- only when --colocation asked
            echo "enable_proximity_placement_group = $ENABLE_COLOCATION" >> terraform.tfvars
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
                    CLIENT_MACHINE_TYPE="Standard_D${CLIENT_VCPUS}s_v6"
                fi
                cat > "$CLIENT_DIR/terraform.tfvars" <<EOFCLIENT
subscription_id = "$AZURE_SUB_ID"
resource_group_name = "$RESOURCE_GROUP"
location = "$LOCATION"
client_name = "${DEPLOYMENT_NAME}-client"
ssh_public_key = "$SSH_PUBLIC_KEY"
# Azure: client shares the storage vnet (fixed mayascale-vnet) -- a per-deployment
# vnet would duplicate the VIP address space. Matches storage module default.
vnet_name = "mayascale-vnet"
subnet_name = "mayascale-subnet"
use_spot = $USE_SPOT
admin_username = "mayascale"
vm_size = "$CLIENT_MACHINE_TYPE"
EOFCLIENT
                # PPG is opt-in via --colocation (storage creates it only then, same
                # gate as enable_proximity_placement_group). A zonal deploy WITHOUT
                # --colocation has no PPG -> don't reference one (else client VM 404s).
                if [ "$ENABLE_COLOCATION" = "true" ]; then
                    PPG_ID="/subscriptions/${AZURE_SUB_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/proximityPlacementGroups/ppg-${DEPLOYMENT_NAME}"
                    echo "proximity_placement_group_id = \"$PPG_ID\"" >> "$CLIENT_DIR/terraform.tfvars"
                fi
                ;;
        esac

        # Init client
        client_state_guard "$CLIENT_DIR" "$RESOURCE_GROUP"
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

        # Azure: client reads the storage vnet (mayascale-vnet) as a data source --
        # wait for storage to create it (appears early, well before VMs) so the
        # parallel client apply doesn't race to a "vnet not found" failure.
        if [ "$CLOUD" = "azure" ]; then
            log "Waiting for storage vnet (mayascale-vnet)..."
            for i in {1..30}; do
                az network vnet show --subscription "$AZURE_SUB_ID" -g "$RESOURCE_GROUP" -n mayascale-vnet -o none 2>/dev/null && break
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
        adopt_placement_policy
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

# Cloud-specific SSH command and placement group info. Prefer plain
# `ssh -i $SSH_PRIVKEY` whenever a public IP is available and we have the
# private key (much faster than gcloud, which probes IAM/IAP/OS Login on
# every invocation). Fall back to `gcloud compute ssh` only for the IAP /
# pubkey-only path on GCP.
SSH_I=""
[ -n "$SSH_PRIVKEY" ] && SSH_I="-i $SSH_PRIVKEY "
SSH_USES_GCLOUD=false

case "$CLOUD" in
    gcp)
        if [ "$ASSIGN_PUBLIC_IP" = "true" ] && [ -n "$NODE1_IP" ] && [ -n "$SSH_PRIVKEY" ]; then
            SSH_BASE="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 ${SSH_I}${SSH_USER}@${NODE1_IP}"
        else
            SSH_USES_GCLOUD=true
            IAP_FLAG=""
            [ "$ASSIGN_PUBLIC_IP" = "false" ] && IAP_FLAG="--tunnel-through-iap"
            SSH_BASE="gcloud compute ssh ${SSH_USER}@${NODE1_NAME} --zone=${ZONE} --project=${PROJECT_ID} --quiet $IAP_FLAG --ssh-flag=-o --ssh-flag=StrictHostKeyChecking=no --ssh-flag=-o --ssh-flag=UserKnownHostsFile=/dev/null"
        fi
        # Derive placement policy name from deployment name (matches terraform naming)
        if [ "$ENABLE_COLOCATION" = "true" ]; then
            PLACEMENT_POLICY_NAME="${DEPLOYMENT_NAME}-placement-policy"
        else
            PLACEMENT_POLICY_NAME=""
        fi
        ;;
    aws)
        SSH_BASE="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${SSH_I}${SSH_USER}@${NODE1_IP}"
        PLACEMENT_GROUP_NAME=$(get_output placement_group_name)
        # Get storage AZ for client colocation
        STORAGE_AZ=$(get_output availability_zone)
        ;;
    azure)
        SSH_BASE="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${SSH_I}${SSH_USER}@${NODE1_IP}"
        VNET_NAME=$(get_output virtual_network_name)
        SUBNET_NAME=$(get_output subnet_name)
        AZURE_SUB_ID="${PROJECT_ID:-$(az account show --query id -o tsv 2>/dev/null || echo "")}"
        # Get PPG ID from cluster_config output
        PPG_ID=$(terraform output -json cluster_config 2>/dev/null | jq -r '.placement_group_id // empty' 2>/dev/null || echo "")
        ;;
esac

# SSH helper function. SSH_USES_GCLOUD selects --command vs positional arg.
run_ssh() {
    if [ "$SSH_USES_GCLOUD" = "true" ]; then
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
    # Drop stale state from a different RG so we don't refresh a prior cluster.
    client_state_guard "$CLIENT_DIR" "$RESOURCE_GROUP"

    if [ -f "$CLIENT_DIR/terraform.tfstate" ]; then
        log "Existing client found - refreshing in background..."
        # Reconcile the PPG ref to the CURRENT storage: a prior deploy may have left
        # a ppg-<name> in tfvars that this storage didn't create (PPG opt-out) ->
        # client VM create 404s on the missing PPG. Strip + re-add per current PPG_ID.
        sed -i '/^proximity_placement_group_id/d' "$CLIENT_DIR/terraform.tfvars" 2>/dev/null
        [ -n "$PPG_ID" ] && echo "proximity_placement_group_id = \"$PPG_ID\"" >> "$CLIENT_DIR/terraform.tfvars"
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
MAX_WAIT=600   # cluster_setup2.sh on Azure with spot + dynamic disk attach often runs ~7-8 min
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
        # Prefer plain ssh/scp when client has a public IP and we have the
        # private key — much faster than gcloud. Fall back to gcloud only
        # for the GCP-IAP / pubkey-only path.
        CLIENT_SSH_I=""
        [ -n "$SSH_PRIVKEY" ] && CLIENT_SSH_I="-i $SSH_PRIVKEY "
        CLIENT_SSH_USES_GCLOUD=false
        case "$CLOUD" in
            gcp)
                if [ -n "$CLIENT_IP" ] && [ -n "$SSH_PRIVKEY" ]; then
                    CLIENT_SSH_BASE="ssh ${CLIENT_SSH_I}-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 ${CLIENT_SSH_USER}@${CLIENT_IP}"
                else
                    CLIENT_SSH_USES_GCLOUD=true
                    CLIENT_SSH_BASE="gcloud compute ssh ${CLIENT_SSH_USER}@${CLIENT_NAME} --zone=${ZONE} --project=${PROJECT_ID} --quiet --ssh-flag=-o --ssh-flag=StrictHostKeyChecking=no --ssh-flag=-o --ssh-flag=UserKnownHostsFile=/dev/null --ssh-flag=-o --ssh-flag=LogLevel=ERROR"
                fi
                ;;
            aws|azure)
                CLIENT_SSH_BASE="ssh ${CLIENT_SSH_I}-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 ${CLIENT_SSH_USER}@${CLIENT_IP}"
                ;;
        esac

        # Client SSH helper. CLIENT_SSH_USES_GCLOUD selects --command vs positional arg.
        run_client_ssh() {
            if [ "$CLIENT_SSH_USES_GCLOUD" = "true" ]; then
                $CLIENT_SSH_BASE --command "$1"
            else
                $CLIENT_SSH_BASE "$1"
            fi
        }

        # Client SCP helper function (files go to user's home directory).
        # Same prefer-direct-when-possible logic.
        copy_to_client() {
            local src="$1"
            local dst="$2"
            if [ "$CLIENT_SSH_USES_GCLOUD" = "true" ]; then
                gcloud compute scp "$src" "${CLIENT_SSH_USER}@${CLIENT_NAME}:~/${dst}" --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
            else
                scp ${CLIENT_SSH_I}-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$src" "${CLIENT_SSH_USER}@${CLIENT_IP}:~/${dst}"
            fi
        }

        # Build csi_backend.json for the client. vg substrate -> the terraform csi_backend
        # output as-is. zfs/zpool substrate -> live pools are data-pool-1/2, so remap the
        # node-level clusterid/VIP pairs (correct in the output regardless of pool naming)
        # onto those names. CSI_DRIVER (--csi) sets the product (mayascale=block/zvol,
        # mayanas=file/NFS) + the driver-named VIP-list key. Works on --skip-deploy resume.
        build_csi_backend() {
            local drv="${1:-$CSI_DRIVER}"
            local raw; raw=$(terraform output -json csi_backend 2>/dev/null) || return 1
            [ -n "$raw" ] || return 1
            if [ "$FSX_MODE" = "true" ]; then
                # Match pools to nodes by VIP order (vip1->node1->data-pool-1), robust whether
                # the output has stale vg names or already-correct data-pool-N names.
                echo "$raw" | jq --arg drv "$drv" '
                    (.mayascale // .mayanas) as $vips
                    | ($vips | split(",")) as $vl
                    | (.pools | to_entries | map(.value) | unique_by(.vip)) as $n
                    | { driver: $drv, ($drv): $vips,
                        pools: (
                          {"data-pool-1": ($n | map(select(.vip==$vl[0]))[0])}
                          + (if ($vl|length) > 1
                             then {"data-pool-2": ($n | map(select(.vip==$vl[1]))[0])}
                             else {} end) ),
                        zone_cluster_map: .zone_cluster_map }'
            else
                echo "$raw" | jq --arg drv "$drv" '
                    (.mayascale // .mayanas) as $vips
                    | del(.mayascale, .mayanas) | .driver = $drv | .[$drv] = $vips'
            fi
        }

        # CSI mode: vg-active-active (always) OR --csi (any substrate). No auto-exported
        # volumes -- stage CSI inputs (csi_backend.json + scripts), skip connect+fio.
        if [ "$VG_MODE" = "true" ] || [ "$CSI_MODE" = "true" ]; then
            # csi_backend.json = the --csi choice (default mayascale).
            CSI_OTHER=$([ "$CSI_DRIVER" = "mayascale" ] && echo mayanas || echo mayascale)
            if build_csi_backend "$CSI_DRIVER" > "$RESULTS_DIR/csi_backend.json" 2>/dev/null && [ -s "$RESULTS_DIR/csi_backend.json" ]; then
                copy_to_client "$RESULTS_DIR/csi_backend.json" csi_backend.json
                success "Staged csi_backend.json on client (driver=$CSI_DRIVER, saved to $RESULTS_DIR)"
                # A ZFS/zpool cluster serves BOTH protocols (zvol+nvme-of AND dataset+NFS),
                # so also stage the other driver's backend -- the client can test block AND
                # file from one deploy, no hand-retag. (vg substrate = block only, skip.)
                if [ "$FSX_MODE" = "true" ] && \
                   build_csi_backend "$CSI_OTHER" > "$RESULTS_DIR/csi_backend_$CSI_OTHER.json" 2>/dev/null && \
                   [ -s "$RESULTS_DIR/csi_backend_$CSI_OTHER.json" ]; then
                    copy_to_client "$RESULTS_DIR/csi_backend_$CSI_OTHER.json" "csi_backend_$CSI_OTHER.json"
                    success "Staged csi_backend_$CSI_OTHER.json on client (driver=$CSI_OTHER) -- same zpool, other protocol"
                fi
            else
                warn "could not build csi_backend.json -- not staged (need jq + a valid csi_backend output)"
            fi
            # csi-client-setup.sh is REQUIRED (it installs the driver). The csi-*-test
            # scripts are INTERNAL CSI sanity tools, not part of this repo -- stage them
            # when present, stay quiet when not, and only advertise the ones actually
            # staged. Warning about them and then printing "Then: ./csi-fio-test.sh" for
            # a file we just failed to copy is worse than saying nothing.
            if [ -f "$SCRIPT_DIR/csi-client-setup.sh" ]; then
                copy_to_client "$SCRIPT_DIR/csi-client-setup.sh" csi-client-setup.sh
                run_client_ssh "chmod +x ~/csi-client-setup.sh"
                success "Staged csi-client-setup.sh on client"
            else
                warn "csi-client-setup.sh not found: $SCRIPT_DIR/csi-client-setup.sh"
            fi
            CSI_TESTS_STAGED=""
            for s in csi-fio-test.sh csi-fio-block-test.sh csi-expand-test.sh csi-sanity-test.sh csi-sanity-multi.sh; do
                [ -f "$SCRIPT_DIR/$s" ] || continue
                copy_to_client "$SCRIPT_DIR/$s" "$s"
                run_client_ssh "chmod +x ~/$s"
                success "Staged $s on client"
                CSI_TESTS_STAGED="$CSI_TESTS_STAGED $s"
            done
            log "On client: sudo ./csi-client-setup.sh --backend-json ~/csi_backend.json --image-tar <img.tar>"
            case "$CSI_TESTS_STAGED" in *csi-fio-test.sh*)
                log "Then:      sudo ./csi-fio-test.sh       --backend-json ~/csi_backend.json   # filesystem (mixed randrw)" ;;
            esac
            case "$CSI_TESTS_STAGED" in *csi-fio-block-test.sh*)
                log "Raw block: sudo ./csi-fio-block-test.sh --backend-json ~/csi_backend.json   # separate r/w IOPS + latency" ;;
            esac
            if [ "$FSX_MODE" = "true" ]; then
                log "Other protocol: same cluster also serves $CSI_OTHER -- redo client-setup + tests with --backend-json ~/csi_backend_$CSI_OTHER.json"
            fi
        else

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
