#!/bin/bash
# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

#
# deploy-lustre.sh — Deploy MayaNAS Unified Lustre Data Platform
#
# Purpose: Bring up a 2-node active-active Lustre cluster on cloud
#          object storage via terraform. Optionally deploy a test client
#          and verify the Lustre mount. No benchmarks — use
#          validate-mayanas.sh for those.
#
# Examples:
#   GCP:
#     ./deploy-lustre.sh --cloud gcp -p mayanas-testing -z us-central1-f \
#         -n lug -m c3d-standard-90 -b 12 --deploy-client
#
#   Azure:
#     ./deploy-lustre.sh --cloud azure -g mayanas-rg -l westus \
#         -n lug -m Standard_D32s_v3 -b 12 --deploy-client
#
# Deployment type defaults to active-active (Lustre HA); override with
# -t single or -t active-passive if needed.
#
set -e
set -o pipefail

# ---- Defaults -----------------------------------------------------------
CLOUD="gcp"
# GCP-specific
PROJECT_ID=""
ZONE=""
REGION=""
# Azure-specific
RESOURCE_GROUP=""
LOCATION=""
# Cloud-neutral
CLUSTER_NAME="lustre-eval"
MACHINE_TYPE=""                    # default set per-cloud after parse
BUCKET_COUNT=12
DEPLOYMENT_TYPE="active-active"
FSNAME="zettafs"
MDT_BACKEND="ldiskfs"              # GCP-only var name; Azure module hardcodes ldiskfs
SOURCE_IMAGE=""                    # default set per-cloud after parse
DEPLOY_CLIENT="false"
CLIENT_MACHINE_TYPE=""             # default set per-cloud after parse
CLIENT_IMAGE=""
DESTROY_MODE="false"
SKIP_DEPLOY="false"
USE_SPOT="false"
ASSIGN_PUBLIC_IP="true"
SSH_KEY_OVERRIDE=""                # --ssh-key <path>: explicit pubkey or .pem to use

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/mayanas-results"
mkdir -p "$RESULTS_DIR"
LOGFILE="$RESULTS_DIR/deploy-lustre-$(date +%Y%m%d_%H%M%S).log"

# ---- Colors -------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()   { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*" | tee -a "$LOGFILE"; }
ok()    { echo -e "${GREEN}✓${NC} $*"   | tee -a "$LOGFILE"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"  | tee -a "$LOGFILE"; }
fail()  { echo -e "${RED}✗${NC} $*"     | tee -a "$LOGFILE"; exit 1; }

# ---- Usage --------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [options]

Deploy MayaNAS Unified Lustre Data Platform (2-node active-active).

Required:
  --cloud <gcp|azure>         Cloud provider
  GCP:
    -p, --project-id <ID>       GCP project ID
    -z, --zone <ZONE>           GCP zone (e.g. us-central1-f)
  Azure:
    -g, --resource-group <RG>   Azure resource group name
    -l, --location <LOC>        Azure location (e.g. westus, eastus)
    -p, --project-id <SUB>      Azure subscription ID (optional —
                                defaults to active 'az account show')

Optional:
  -n, --cluster-name <NAME>   Cluster name prefix (default: $CLUSTER_NAME)
  -m, --machine-type <TYPE>   Storage node machine type
                              (GCP default: c3d-standard-90;
                               Azure default: Standard_D32s_v3)
  -b, --buckets <COUNT>       Object-storage buckets per node (default: $BUCKET_COUNT)
  -t, --deployment-type <T>   single | active-passive | active-active
                              (default: $DEPLOYMENT_TYPE — required for Lustre HA)
      --fsname <NAME>         Lustre filesystem name, 1-8 lowercase chars
                              (default: $FSNAME)
      --mdt-backend <BE>      ldiskfs | zfs (GCP only — Azure hardcoded ldiskfs)
                              (default: $MDT_BACKEND)
      --source-image <IMG>    MayaNAS Lustre image
                              (GCP: image family in zettalane-public,
                                    default: mayanas-openzfs-lustre;
                               Azure: full vm_image_id, default: shared image
                                      gallery zettalaneDev/mayanas19/latest
                                      — Lustre lives in mayanas19 from
                                      version 1.9.20260424 onward)

  --deploy-client [TYPE]      Also deploy a test client VM and mount Lustre.
                              Optional TYPE = machine type
                              (GCP default: c4-highcpu-96;
                               Azure default: Standard_D8s_v5)
      --client-image <IMG>    Client boot image (cloud-specific spec).
                              GCP example: rocky-linux-cloud/rocky-linux-10
                              Azure: not used (cloud-init handles image)

  -s, --spot                  Use spot / preemptible instances (cheaper)
      --no-public-ip          Storage nodes with no public IPs.
                              GCP: auto-enables Private Google Access + IAP.
                              Azure: pure private (no Bastion auto-config).
                              (default: public IPs ON for zero-friction eval)

  -k, --ssh-key <path>        SSH key to bake into the VMs (REQUIRED).
                              Either a public key (ssh-rsa/ssh-ed25519/...)
                              or a private key (.pem / OpenSSH) — the type
                              is detected from the file content. For private
                              keys the public half is derived via ssh-keygen
                              and cached at <path>.pub.

  --skip-deploy               Reuse existing storage cluster (skip its terraform
                              apply). Client --deploy-client still runs.
  --destroy                   Tear down (reverse of deploy)
  -h, --help                  Show this help

Examples:
  GCP:
    $0 --cloud gcp -p mayanas-testing -z us-central1-f -n lug \\
       -m c3d-standard-90 -b 12 --deploy-client

  Azure:
    $0 --cloud azure -g mayanas-rg -l westus -n lug \\
       -m Standard_D32s_v3 -b 12 --deploy-client

After deploy: use terraform outputs to mount Lustre:
  cd $SCRIPT_DIR/<cloud>/mayanas && terraform output lustre_mount_command
EOF
    exit 0
}

# ---- Parse args ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cloud)               CLOUD="$2"; shift 2 ;;
        -p|--project-id)       PROJECT_ID="$2"; shift 2 ;;
        -z|--zone)             ZONE="$2"; shift 2 ;;
        -g|--resource-group)   RESOURCE_GROUP="$2"; shift 2 ;;
        -l|--location)         LOCATION="$2"; shift 2 ;;
        -n|--cluster-name)     CLUSTER_NAME="$2"; shift 2 ;;
        -m|--machine-type)     MACHINE_TYPE="$2"; shift 2 ;;
        -b|--buckets)          BUCKET_COUNT="$2"; shift 2 ;;
        -t|--deployment-type)  DEPLOYMENT_TYPE="$2"; shift 2 ;;
        --fsname)              FSNAME="$2"; shift 2 ;;
        --mdt-backend)         MDT_BACKEND="$2"; shift 2 ;;
        --source-image)        SOURCE_IMAGE="$2"; shift 2 ;;
        --deploy-client)
            DEPLOY_CLIENT="true"
            if [[ -n "${2:-}" && "$2" != -* ]]; then
                CLIENT_MACHINE_TYPE="$2"
                shift 2
            else
                shift
            fi
            ;;
        --client-machine-type) CLIENT_MACHINE_TYPE="$2"; shift 2 ;;
        --client-image)        CLIENT_IMAGE="$2"; shift 2 ;;
        -s|--spot)             USE_SPOT="true"; shift ;;
        --no-public-ip)        ASSIGN_PUBLIC_IP="false"; shift ;;
        -k|--ssh-key)          SSH_KEY_OVERRIDE="$2"; shift 2 ;;
        --skip-deploy)         SKIP_DEPLOY="true"; shift ;;
        --destroy)             DESTROY_MODE="true"; shift ;;
        -h|--help)             usage ;;
        *)                     fail "Unknown option: $1 (run with --help)" ;;
    esac
done

# ---- Cloud-specific setup ----------------------------------------------
case "$CLOUD" in
    gcp)
        [ -n "$PROJECT_ID" ] || fail "--project-id is required for GCP"
        [ -n "$ZONE" ]       || fail "--zone is required for GCP"
        REGION="${ZONE%-*}"
        MAYANAS_DIR="$SCRIPT_DIR/gcp/mayanas"
        CLIENT_DIR="$SCRIPT_DIR/gcp/client-testing"
        SSH_USER_DEFAULT="mayanas"
        : "${MACHINE_TYPE:=c3d-standard-90}"
        : "${CLIENT_MACHINE_TYPE:=c4-highcpu-96}"
        : "${SOURCE_IMAGE:=mayanas-openzfs-lustre}"
        # Lustre client default: Rocky 10. Whamcloud's Lustre 2.17 DKMS
        # package builds cleanly against its kernel; Ubuntu 24.04 HWE kernel
        # is incompatible with Lustre 2.17 source. The gcp/client-testing
        # module itself defaults to Ubuntu (for validate-mayanas NFS tests),
        # so we override here.
        : "${CLIENT_IMAGE:=rocky-linux-cloud/rocky-linux-10}"
        command -v gcloud >/dev/null || fail "gcloud binary not found in PATH"

        # GCP pre-flight: Compute Engine API must be enabled (otherwise
        # terraform fails 5 minutes in). Marketplace agreement acceptance
        # for VM products is UI-only on GCP — no public API to query or
        # accept programmatically — so we just print a heads-up.
        if ! gcloud services list --enabled --project="$PROJECT_ID" \
                --filter='config.name=compute.googleapis.com' \
                --format='value(name)' 2>/dev/null | grep -q compute; then
            echo
            fail "Compute Engine API not enabled in project $PROJECT_ID
       Enable with:
         gcloud services enable compute.googleapis.com --project=$PROJECT_ID
       Or via Console:
         https://console.cloud.google.com/apis/library/compute.googleapis.com?project=$PROJECT_ID"
        fi
        ;;
    azure)
        [ -n "$RESOURCE_GROUP" ] || fail "--resource-group is required for Azure"
        [ -n "$LOCATION" ]       || fail "--location is required for Azure (e.g. westus)"
        MAYANAS_DIR="$SCRIPT_DIR/azure/mayanas"
        CLIENT_DIR="$SCRIPT_DIR/azure/client-testing"
        SSH_USER_DEFAULT="azureuser"
        : "${MACHINE_TYPE:=Standard_D32s_v3}"
        : "${CLIENT_MACHINE_TYPE:=Standard_D8s_v5}"
        command -v az >/dev/null || fail "az binary not found in PATH"
        # On Azure, -p / --project-id carries the subscription ID (mirrors
        # internal validate-mayanas.sh).  Fall back to active az account if
        # the flag wasn't supplied.
        if [ -n "$PROJECT_ID" ]; then
            AZURE_SUB_ID="$PROJECT_ID"
        else
            AZURE_SUB_ID=$(az account show --query id -o tsv 2>/dev/null) \
                || fail "az account show failed — run 'az login' first, or pass -p <subscription-id>"
        fi
        # Default vm_image_id points at the public zettalanePub/openzfs-lustre
        # image-def (created by create-lustre-image.sh with no Marketplace
        # plan attached — VMs from this image have no per-hour plan billing
        # and need no accept-terms step). The gallery lives in the ZettaLane
        # subscription regardless of which subscription the customer deploys
        # VMs into, so we hardcode it here. Subscription IDs are public-by-
        # design identifiers (Marketplace URIs etc), not credentials.
        # Override the whole path via --source-image if needed.
        : "${SOURCE_IMAGE:=/subscriptions/a1374ce4-3087-440a-9af3-674d883c6d3f/resourceGroups/ZETTALANE-DEV/providers/Microsoft.Compute/galleries/zettalanePub/images/openzfs-lustre/versions/latest}"

        # Azure Marketplace pre-flight: if the image-def has a plan attached
        # (e.g. zettalanePub/mayanas19 has 'mayanas-cloud-ent'), the customer's
        # subscription must have accepted the plan terms before deploy. Plan-less
        # image-defs (e.g. zettalanePub/openzfs-lustre, which we created without
        # --plan-* flags) auto-pass — purchasePlan returns null, no check needed.
        case "$SOURCE_IMAGE" in
            /subscriptions/*/galleries/*/images/*/versions/*)
                IMGDEF_URI=$(echo "$SOURCE_IMAGE" | sed 's|/versions/[^/]*$||')
                PLAN_PUB=$(az resource show --ids "$IMGDEF_URI" \
                    --query 'properties.purchasePlan.publisher' -o tsv 2>/dev/null)
                if [ -n "$PLAN_PUB" ] && [ "$PLAN_PUB" != "None" ]; then
                    PLAN_PRD=$(az resource show --ids "$IMGDEF_URI" \
                        --query 'properties.purchasePlan.product' -o tsv 2>/dev/null)
                    PLAN_NAM=$(az resource show --ids "$IMGDEF_URI" \
                        --query 'properties.purchasePlan.name' -o tsv 2>/dev/null)
                    ACCEPTED=$(az vm image terms show \
                        --publisher "$PLAN_PUB" --offer "$PLAN_PRD" --plan "$PLAN_NAM" \
                        --subscription "$AZURE_SUB_ID" \
                        --query 'accepted' -o tsv 2>/dev/null || echo "false")
                    if [ "$ACCEPTED" != "True" ]; then
                        echo
                        fail "Azure Marketplace plan terms not accepted in subscription $AZURE_SUB_ID
       Plan: $PLAN_PUB / $PLAN_PRD / $PLAN_NAM
       Accept once with:
         az vm image terms accept --publisher $PLAN_PUB --offer $PLAN_PRD --plan $PLAN_NAM --subscription $AZURE_SUB_ID
       Or via terraform: add an azurerm_marketplace_agreement resource."
                    fi
                fi
                ;;
        esac
        ;;
    *)
        fail "Unknown --cloud: $CLOUD (use 'gcp' or 'azure')"
        ;;
esac

[ -d "$MAYANAS_DIR" ] || fail "Expected $MAYANAS_DIR to exist"
[[ "$FSNAME" =~ ^[a-z][a-z0-9]{0,7}$ ]] || fail "--fsname must be 1-8 lowercase alphanumeric, starting with a letter"
command -v terraform >/dev/null || fail "terraform binary not found in PATH"

# ---- Banner -------------------------------------------------------------
echo
echo -e "${BOLD}MayaNAS Unified Lustre Data Platform — Deploy${NC}"
echo "  Log:          $LOGFILE"
echo "  Cloud:        $CLOUD"
case "$CLOUD" in
    gcp)
        echo "  Project:      $PROJECT_ID"
        echo "  Zone/Region:  $ZONE / $REGION"
        ;;
    azure)
        echo "  Subscription: $AZURE_SUB_ID"
        echo "  Resource Grp: $RESOURCE_GROUP"
        echo "  Location:     $LOCATION"
        ;;
esac
echo "  Cluster:      $CLUSTER_NAME"
echo "  Machine:      $MACHINE_TYPE  ·  buckets: $BUCKET_COUNT"
echo "  Deployment:   $DEPLOYMENT_TYPE  ·  fsname: $FSNAME"
[ "$CLOUD" = "gcp" ] && echo "  MDT backend:  $MDT_BACKEND"
echo "  Image:        $SOURCE_IMAGE"
echo "  Spot:         $USE_SPOT  ·  Public IP: $ASSIGN_PUBLIC_IP"
[ "$DEPLOY_CLIENT" = "true" ] && echo "  Client:       $CLIENT_MACHINE_TYPE"
echo

# ---- Resolve --ssh-key into the public-key string -----------------------
# Mandatory. Detects file type from first line:
#   ssh-rsa / ssh-ed25519 / ssh-ecdsa-* / ecdsa-sha*  → public key, used as-is.
#   -----BEGIN ... PRIVATE KEY-----                   → private key, derive
#                                                       public half via
#                                                       ssh-keygen -y (no
#                                                       file written).
if [ -z "$SSH_KEY_OVERRIDE" ]; then
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
[ -r "$SSH_KEY_OVERRIDE" ] || fail "--ssh-key: cannot read $SSH_KEY_OVERRIDE"
SSH_PRIVKEY=""   # set when --ssh-key points to a private key, used for -i
# Use ssh-keygen as the authority on whether this is a private key — handles
# RSA/OpenSSH/PKCS8 formats, with or without trailing CRLF / BOM.
if SSH_PUBKEY=$(ssh-keygen -y -f "$SSH_KEY_OVERRIDE" 2>/dev/null); then
    SSH_PRIVKEY="$SSH_KEY_OVERRIDE"
else
    SSH_KEY_TYPE=$(awk 'NR==1{print $1; exit}' "$SSH_KEY_OVERRIDE")
    case "$SSH_KEY_TYPE" in
        ssh-rsa|ssh-ed25519|ssh-dss|ssh-ecdsa-*|ecdsa-sha2-*|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-*)
            SSH_PUBKEY=$(cat "$SSH_KEY_OVERRIDE")
            ;;
        *)
            fail "--ssh-key: $SSH_KEY_OVERRIDE is not a recognized SSH key file (first token: '$SSH_KEY_TYPE')"
            ;;
    esac
fi
[ -n "$SSH_PUBKEY" ] || fail "--ssh-key: derived empty public key from $SSH_KEY_OVERRIDE"

# ---- Destroy path -------------------------------------------------------
if [ "$DESTROY_MODE" = "true" ]; then
    log "Destroying Lustre deployment... (verbose terraform output → $LOGFILE)"

    if [ -f "$CLIENT_DIR/terraform.tfstate" ]; then
        log "Tearing down client..."
        (cd "$CLIENT_DIR" && terraform destroy -auto-approve -input=false) >> "$LOGFILE" 2>&1 \
            && ok "Client destroyed" \
            || warn "Client destroy had errors — see $LOGFILE"
    fi

    log "Tearing down storage cluster..."
    if (cd "$MAYANAS_DIR" && terraform destroy -auto-approve -input=false) >> "$LOGFILE" 2>&1; then
        ok "Storage cluster destroyed"
    else
        case "$CLOUD" in
            gcp)
                # GCS sometimes can't delete non-empty buckets even with force_destroy.
                warn "First destroy failed (likely non-empty GCS buckets) — emptying via gsutil then retrying"
                if (cd "$MAYANAS_DIR" && terraform output -json gcs_bucket_names) >/dev/null 2>&1; then
                    (cd "$MAYANAS_DIR" && terraform output -json gcs_bucket_names) \
                        | jq -r '.[]' 2>/dev/null \
                        | while read -r bucket; do
                            [ -n "$bucket" ] || continue
                            log "  emptying gs://$bucket"
                            ( gsutil -m rm -r "gs://$bucket/**" >/dev/null 2>&1 || true ) &
                        done
                    wait
                else
                    warn "  could not read gcs_bucket_names output; skipping gsutil empty"
                fi
                ;;
            azure)
                # Azure storage account containers can also block destroy.
                warn "First destroy failed — emptying storage containers then retrying"
                STORAGE_ACCT=$(cd "$MAYANAS_DIR" && terraform output -raw storage_account_name 2>/dev/null || echo "")
                if [ -n "$STORAGE_ACCT" ]; then
                    KEY=$(az storage account keys list --account-name "$STORAGE_ACCT" \
                          --resource-group "$RESOURCE_GROUP" --query '[0].value' -o tsv 2>/dev/null || echo "")
                    if [ -n "$KEY" ]; then
                        az storage container list --account-name "$STORAGE_ACCT" --account-key "$KEY" \
                            --query '[].name' -o tsv 2>/dev/null | while read -r container; do
                                [ -n "$container" ] || continue
                                log "  emptying container $container"
                                ( az storage blob delete-batch --source "$container" \
                                    --account-name "$STORAGE_ACCT" --account-key "$KEY" >/dev/null 2>&1 || true ) &
                            done
                        wait
                    else
                        warn "  could not get storage account key; skipping container empty"
                    fi
                fi
                ;;
        esac

        log "Retrying terraform destroy..."
        (cd "$MAYANAS_DIR" && terraform destroy -auto-approve -input=false) >> "$LOGFILE" 2>&1 \
            && ok "Storage cluster destroyed (after bucket cleanup)" \
            || fail "MayaNAS destroy failed even after bucket cleanup — see $LOGFILE"
    fi

    ok "Teardown complete"
    echo "Log: $LOGFILE"
    exit 0
fi

# ---- Generate tfvars for storage module ---------------------------------
TFVARS="$MAYANAS_DIR/terraform.tfvars"
log "Writing $TFVARS"

case "$CLOUD" in
    gcp)
        cat > "$TFVARS" <<EOF
# Auto-generated by deploy-lustre.sh — $(date)
project_id    = "$PROJECT_ID"
region        = "$REGION"
zones         = ["$ZONE"]
cluster_name  = "$CLUSTER_NAME"
machine_type  = "$MACHINE_TYPE"
bucket_count  = $BUCKET_COUNT
deployment_type = "$DEPLOYMENT_TYPE"
source_image_project = "zettalane-public"
source_image_family  = "$SOURCE_IMAGE"

# Lustre protocol support
enable_lustre       = true
fsname              = "$FSNAME"
lustre_mdt_backend  = "$MDT_BACKEND"

# Cost / access toggles
use_spot_vms        = $USE_SPOT
assign_public_ip    = $ASSIGN_PUBLIC_IP
# Auto-enable IAP tunnel when public IPs are off, so the operator still has
# a way to SSH into storage nodes (gcloud compute ssh --tunnel-through-iap).
enable_iap          = $([ "$ASSIGN_PUBLIC_IP" = "false" ] && echo true || echo false)

# Allow destroy to force-remove non-empty GCS buckets
force_destroy_buckets = true
EOF
        ;;
    azure)
        # Azure module needs ssh_public_key; resolved from --ssh-key earlier.
        cat > "$TFVARS" <<EOF
# Auto-generated by deploy-lustre.sh — $(date)
subscription_id     = "$AZURE_SUB_ID"
resource_group_name = "$RESOURCE_GROUP"
location            = "$LOCATION"
cluster_name        = "$CLUSTER_NAME"
deployment_type     = "$DEPLOYMENT_TYPE"
vm_size             = "$MACHINE_TYPE"
bucket_count        = $BUCKET_COUNT
use_spot_instance   = $USE_SPOT
ssh_cidr_blocks     = ["0.0.0.0/0"]
assign_public_ip    = $ASSIGN_PUBLIC_IP
ssh_public_key      = "$SSH_PUBKEY"
vm_image_id         = "$SOURCE_IMAGE"

# Lustre protocol support (Azure module hardcodes ldiskfs MDT)
enable_lustre       = true
fsname              = "$FSNAME"
EOF
        ;;
esac

# ---- Terraform apply ----------------------------------------------------
if [ "$SKIP_DEPLOY" = "true" ]; then
    log "--skip-deploy: reusing existing storage deployment"
    [ -f "$MAYANAS_DIR/terraform.tfstate" ] || fail "No terraform.tfstate in $MAYANAS_DIR — run without --skip-deploy first"
    (cd "$MAYANAS_DIR" && terraform output -raw lustre_mount_command >/dev/null 2>&1) \
        || fail "Existing state doesn't look like a Lustre deploy (no lustre_mount_command output)"
    ok "Storage cluster reused"
else
    log "terraform init..."
    (cd "$MAYANAS_DIR" && terraform init -input=false) >> "$LOGFILE" 2>&1 || fail "terraform init failed (see $LOGFILE)"

    log "terraform apply (may take 5-10 min for VM boot + cluster setup)..."
    # awk (not grep) so the filter command always exits 0 regardless of matches —
    # grep+|| true clobbers PIPESTATUS, masking terraform failures.
    (cd "$MAYANAS_DIR" && terraform apply -auto-approve -input=false) 2>&1 | tee -a "$LOGFILE" | awk '/Apply complete|Error|error/ { print }'
    APPLY_RC=${PIPESTATUS[0]}
    [ "$APPLY_RC" -eq 0 ] || fail "terraform apply failed (exit $APPLY_RC) — see $LOGFILE"

    (cd "$MAYANAS_DIR" && terraform output -raw lustre_mount_command >/dev/null 2>&1) \
        || fail "terraform apply succeeded but lustre_mount_command output is missing — see $LOGFILE"

    ok "Storage cluster deployed"
fi

# ---- Summary from outputs -----------------------------------------------
echo
echo -e "${BOLD}Deployment summary${NC}"
cd "$MAYANAS_DIR"
NODE1_NAME=$(terraform output -raw node1_name 2>/dev/null || echo "")
NODE2_NAME=$(terraform output -raw node2_name 2>/dev/null || echo "")
VIP=$(terraform output -raw vip_address 2>/dev/null || echo "")
VIP2=$(terraform output -raw vip_address_2 2>/dev/null || echo "")
MGS_NID=$(terraform output -raw lustre_mgs_nid 2>/dev/null || echo "")
MOUNT_CMD=$(terraform output -raw lustre_mount_command 2>/dev/null || echo "")

echo "  Node 1:        $NODE1_NAME"
[ -n "$NODE2_NAME" ] && echo "  Node 2:        $NODE2_NAME"
echo "  VIP primary:   $VIP"
[ -n "$VIP2" ] && echo "  VIP secondary: $VIP2"
echo "  MGS NID:       $MGS_NID"
echo "  Mount command: $MOUNT_CMD"
cd "$SCRIPT_DIR"

# ---- Optional client deploy --------------------------------------------
if [ "$DEPLOY_CLIENT" = "true" ]; then
    [ -d "$CLIENT_DIR" ] || fail "Client module missing at $CLIENT_DIR"

    log "Using SSH key: $SSH_KEY_OVERRIDE"

    CLIENT_TFVARS="$CLIENT_DIR/terraform.tfvars"
    log "Writing $CLIENT_TFVARS"

    case "$CLOUD" in
        gcp)
            cat > "$CLIENT_TFVARS" <<EOF
project_id     = "$PROJECT_ID"
zone           = "$ZONE"
client_name    = "${CLUSTER_NAME}-client"
machine_type   = "$CLIENT_MACHINE_TYPE"
ssh_public_key = "$SSH_PUBKEY"
use_spot       = $USE_SPOT
EOF
            [ -n "$CLIENT_IMAGE" ] && echo "source_image   = \"$CLIENT_IMAGE\"" >> "$CLIENT_TFVARS"
            ;;
        azure)
            # Pull vnet/subnet from the storage module's outputs so the client lands
            # in the same VNet as the storage nodes and can hit them via private IP.
            VNET_NAME=$(cd "$MAYANAS_DIR" && terraform output -raw vnet_name 2>/dev/null || echo "")
            SUBNET_NAME=$(cd "$MAYANAS_DIR" && terraform output -raw subnet_name 2>/dev/null || echo "")
            [ -n "$VNET_NAME" ]   || fail "Could not get vnet_name from storage outputs — re-run terraform apply"
            [ -n "$SUBNET_NAME" ] || fail "Could not get subnet_name from storage outputs"
            # Lustre client on Azure: Rocky 9 (Whamcloud Lustre 2.17 DKMS
            # builds cleanly against its kernel). The azure/client-testing
            # module itself defaults to Ubuntu 24.04 (for validate-mayanas
            # NFS tests), so we override back here.
            cat > "$CLIENT_TFVARS" <<EOF
subscription_id        = "$AZURE_SUB_ID"
resource_group_name    = "$RESOURCE_GROUP"
location               = "$LOCATION"
vnet_name              = "$VNET_NAME"
subnet_name            = "$SUBNET_NAME"
client_name            = "${CLUSTER_NAME}-client"
vm_size                = "$CLIENT_MACHINE_TYPE"
ssh_public_key         = "$SSH_PUBKEY"
use_spot               = $USE_SPOT
source_image_publisher = "resf"
source_image_offer     = "rockylinux-x86_64"
source_image_sku       = "9-base"
EOF
            ;;
    esac

    log "Deploying (or reconciling) client VM..."
    (cd "$CLIENT_DIR" && terraform init -input=false) >> "$LOGFILE" 2>&1 || fail "client terraform init failed"
    (cd "$CLIENT_DIR" && terraform apply -auto-approve -input=false) 2>&1 | tee -a "$LOGFILE" | awk '/Apply complete|Error|error/ { print }'
    CLIENT_RC=${PIPESTATUS[0]}
    [ "$CLIENT_RC" -eq 0 ] || fail "client terraform apply failed (exit $CLIENT_RC) — see $LOGFILE"

    CLIENT_NAME=$(cd "$CLIENT_DIR" && terraform output -raw client_name 2>/dev/null || echo "${CLUSTER_NAME}-client")
    SSH_USER=$(cd "$CLIENT_DIR" && terraform output -raw ssh_user 2>/dev/null || echo "$SSH_USER_DEFAULT")
    CLIENT_PUBIP=$(cd "$CLIENT_DIR" && terraform output -raw client_public_ip 2>/dev/null || echo "")

    ok "Client $CLIENT_NAME ready"

    # ---- Cloud-specific SSH wrapper -------------------------------------
    # Prefer direct ssh/scp via public IP whenever available (much faster than
    # gcloud, which probes IAM/IAP/OS Login on every invocation). Fall back to
    # gcloud only for the GCP-IAP / pubkey-only path.
    SSH_I_FLAG=""
    [ -n "$SSH_PRIVKEY" ] && SSH_I_FLAG="-i $SSH_PRIVKEY"
    USE_GCLOUD_SSH=false
    case "$CLOUD" in
        gcp)
            if [ -n "$CLIENT_PUBIP" ] && [ -n "$SSH_PRIVKEY" ]; then
                ssh_to_client() {
                    ssh $SSH_I_FLAG -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                        "${SSH_USER}@${CLIENT_PUBIP}" "$1"
                }
                scp_to_client() {
                    scp $SSH_I_FLAG -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                        "$1" "${SSH_USER}@${CLIENT_PUBIP}:$2"
                }
            else
                USE_GCLOUD_SSH=true
                ssh_to_client() {
                    gcloud compute ssh "${SSH_USER}@${CLIENT_NAME}" \
                        --zone="$ZONE" --project="$PROJECT_ID" --quiet \
                        --command="$1"
                }
                scp_to_client() {
                    gcloud compute scp "$1" "${SSH_USER}@${CLIENT_NAME}:$2" \
                        --zone="$ZONE" --project="$PROJECT_ID"
                }
            fi
            ;;
        azure)
            [ -n "$CLIENT_PUBIP" ] || fail "Client has no public IP — cannot SSH to install Lustre client"
            ssh_to_client() {
                ssh $SSH_I_FLAG -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    "${SSH_USER}@${CLIENT_PUBIP}" "$1"
            }
            scp_to_client() {
                scp $SSH_I_FLAG -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    "$1" "${SSH_USER}@${CLIENT_PUBIP}:$2"
            }
            ;;
    esac

    log "Waiting for client SSH..."
    for attempt in 1 2 3 4 5 6; do
        if ssh_to_client "echo ready" >/dev/null 2>&1; then
            break
        fi
        log "  waiting for client SSH (attempt $attempt/6)..."
        sleep 20
    done

    INSTALLER="$SCRIPT_DIR/install-lustre-client.sh"
    if [ -r "$INSTALLER" ]; then
        log "Copying install-lustre-client.sh to client"
        scp_to_client "$INSTALLER" "/tmp/" 2>&1 | tee -a "$LOGFILE" | tail -3 || \
            fail "Failed to scp install-lustre-client.sh to client"

        log "Running install-lustre-client.sh on client (5-10 min for build)..."
        # Capture exit code via PIPESTATUS so tee/tail don't swallow it.
        ssh_to_client "sudo bash /tmp/install-lustre-client.sh" 2>&1 | tee -a "$LOGFILE" | tail -5
        INSTALL_RC=${PIPESTATUS[0]}
        if [ "$INSTALL_RC" -eq 100 ]; then
            # Installer can't find matching kernel-devel for the running
            # kernel — fall back to BYOC mode (skip auto-mount) and let the
            # final-message BYOC block tell the user how to set up Lustre
            # on this VM (or any other Linux box) themselves.
            warn "Client lacks matching kernel-devel — falling back to bring-your-own-client mode"
            BYOC_FALLBACK=true
        elif [ "$INSTALL_RC" -ne 0 ]; then
            fail "install-lustre-client.sh failed on client (exit $INSTALL_RC) — see $LOGFILE"
        else
            ok "Lustre client installed"

            log "Mounting zettafs and verifying..."
            ssh_to_client "
                sudo modprobe lustre 2>&1
                sudo mkdir -p /mnt/lustre
                sudo $MOUNT_CMD 2>&1
                echo '--- lfs df ---'
                lfs df -h 2>&1 | head -6
                echo '--- lfs check servers ---'
                lfs check servers 2>&1 | head -5
            " 2>&1 | tee -a "$LOGFILE" | tail -15
            ok "zettafs mounted at /mnt/lustre on $CLIENT_NAME"
        fi
    else
        warn "install-lustre-client.sh not found at $INSTALLER — skipping auto-install"
        warn "Client VM is bare; user can scp + run the script manually."
    fi
fi

# ---- Final success message ----------------------------------------------
echo
echo -e "${BOLD}${GREEN}=== Deploy complete ===${NC}"
echo
echo -e "${BOLD}Storage cluster${NC}"
echo "  Node 1:         $NODE1_NAME"
[ -n "$NODE2_NAME" ] && echo "  Node 2:         $NODE2_NAME"
echo "  MGS NID:        $MGS_NID"
echo "  Filesystem:     $FSNAME"
echo "  VIP primary:    $VIP"
[ -n "$VIP2" ] && echo "  VIP secondary:  $VIP2"
echo

# Cloud-specific node SSH instructions
case "$CLOUD" in
    gcp)
        NODE1_PUBIP=$(cd "$MAYANAS_DIR" && terraform output -raw node1_public_ip 2>/dev/null || echo "")
        SSH_I=""
        [ -n "${SSH_PRIVKEY:-}" ] && SSH_I="-i $SSH_PRIVKEY "
        if [ "$ASSIGN_PUBLIC_IP" = "false" ]; then
            echo "Connect to node 1 via IAP (no public IP):"
            echo "  gcloud compute ssh mayanas@$NODE1_NAME --zone=$ZONE --project=$PROJECT_ID --tunnel-through-iap"
        elif [ -n "$NODE1_PUBIP" ] && [ -n "${SSH_PRIVKEY:-}" ]; then
            echo "Connect to node 1:"
            echo "  ssh ${SSH_I}mayanas@$NODE1_PUBIP"
        else
            echo "Connect to node 1:"
            echo "  gcloud compute ssh mayanas@$NODE1_NAME --zone=$ZONE --project=$PROJECT_ID"
        fi
        ;;
    azure)
        SSH_I=""
        [ -n "${SSH_PRIVKEY:-}" ] && SSH_I="-i $SSH_PRIVKEY "
        NODE1_IP=$(cd "$MAYANAS_DIR" && terraform output -raw node1_public_ip 2>/dev/null || echo "")
        if [ -n "$NODE1_IP" ] && [ "$ASSIGN_PUBLIC_IP" = "true" ]; then
            echo "Connect to node 1:"
            echo "  ssh ${SSH_I}azureuser@$NODE1_IP"
        else
            echo "Connect to node 1 (private IP — use bastion / VPN):"
            echo "  ssh ${SSH_I}azureuser@<node1-private-ip>"
        fi
        ;;
esac
echo
echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"

if [ "$DEPLOY_CLIENT" = "true" ] && [ "${BYOC_FALLBACK:-false}" != "true" ]; then
    echo -e "${BOLD}Client VM  —  Lustre installed, zettafs mounted at /mnt/lustre${NC}"
    echo "  Name:    $CLIENT_NAME"
    [ -n "$CLIENT_PUBIP" ] && echo "  Public:  $CLIENT_PUBIP"
    case "$CLOUD" in
        gcp)
            if [ "$USE_GCLOUD_SSH" = "true" ]; then
                echo "  SSH:     gcloud compute ssh ${SSH_USER}@${CLIENT_NAME} --zone=$ZONE --project=$PROJECT_ID"
            else
                echo "  SSH:     ssh ${SSH_I}${SSH_USER}@${CLIENT_PUBIP}"
            fi
            ;;
        azure)
            echo "  SSH:     ssh ${SSH_I}${SSH_USER}@${CLIENT_PUBIP}"
            ;;
    esac
    echo "  Mount:   $MOUNT_CMD"
    echo
    echo "Verify on the client:"
    case "$CLOUD" in
        gcp)
            if [ "$USE_GCLOUD_SSH" = "true" ]; then
                echo "  gcloud compute ssh ${SSH_USER}@${CLIENT_NAME} --zone=$ZONE --project=$PROJECT_ID --command='lfs df -h; lfs check servers'"
            else
                echo "  ssh ${SSH_I}${SSH_USER}@${CLIENT_PUBIP} 'lfs df -h; lfs check servers'"
            fi
            ;;
        azure)
            echo "  ssh ${SSH_I}${SSH_USER}@${CLIENT_PUBIP} 'lfs df -h; lfs check servers'"
            ;;
    esac
else
    echo -e "${BOLD}Mount zettafs from your own Linux client${NC}"
    echo
    echo "1. Install the Lustre 2.17 client:"
    echo "   Helper script (same dir as this one):"
    echo "     sudo bash $SCRIPT_DIR/install-lustre-client.sh"
    echo "   Or manually from Whamcloud:"
    echo "     https://downloads.whamcloud.com/public/lustre/lustre-2.17.0/"
    echo "     (el9.7 / el10.1 / ubuntu2404 / sles15sp7)"
    echo
    echo "2. Load modules and mount:"
    echo "     sudo modprobe lustre"
    echo "     sudo mkdir -p /mnt/lustre"
    echo "     sudo $MOUNT_CMD"
    echo
    echo "3. Verify:"
    echo "     lfs df -h"
    echo "     lfs check servers"
fi

echo
echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"
echo "Tear down:"
case "$CLOUD" in
    gcp)
        echo "  $0 --cloud $CLOUD -p $PROJECT_ID -z $ZONE -n $CLUSTER_NAME --destroy"
        ;;
    azure)
        echo "  $0 --cloud $CLOUD -g $RESOURCE_GROUP -l $LOCATION -p $AZURE_SUB_ID -n $CLUSTER_NAME --destroy"
        ;;
esac
echo
echo "Log: $LOGFILE"
