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
# Example:
#   ./deploy-lustre.sh --cloud gcp -b 12 -p mayanas-testing \
#       -m c3d-standard-90 -n lug -z us-central1-f \
#       --deploy-client --client-machine-type c4-highcpu-96
#
# Deployment type defaults to active-active (Lustre HA); override with
# -t single or -t active-passive if needed.
#
set -e
set -o pipefail

# ---- Defaults -----------------------------------------------------------
CLOUD="gcp"
PROJECT_ID=""
ZONE=""
REGION=""
CLUSTER_NAME="lustre-eval"
MACHINE_TYPE="c3d-standard-90"
BUCKET_COUNT=12
DEPLOYMENT_TYPE="active-active"
FSNAME="zettafs"
MDT_BACKEND="ldiskfs"
SOURCE_IMAGE="mayanas-openzfs-lustre"   # image FAMILY in zettalane-public — resolves to latest
DEPLOY_CLIENT="false"
CLIENT_MACHINE_TYPE="c4-highcpu-96"
CLIENT_IMAGE=""                   # empty → client module default (Ubuntu 24.04)
DESTROY_MODE="false"
SKIP_DEPLOY="false"
USE_SPOT="false"
ASSIGN_PUBLIC_IP="true"

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
  --cloud <gcp>               Cloud provider (currently only 'gcp')
  -p, --project-id <ID>       GCP project ID
  -z, --zone <ZONE>           GCP zone (e.g. us-central1-f)

Optional:
  -n, --cluster-name <NAME>   Cluster name prefix (default: $CLUSTER_NAME)
  -m, --machine-type <TYPE>   Storage node machine type (default: $MACHINE_TYPE)
  -b, --buckets <COUNT>       GCS buckets per node (default: $BUCKET_COUNT)
  -t, --deployment-type <T>   single | active-passive | active-active
                              (default: $DEPLOYMENT_TYPE — required for Lustre HA)
      --fsname <NAME>         Lustre filesystem name, 1-8 lowercase chars
                              (default: $FSNAME)
      --mdt-backend <BE>      ldiskfs | zfs  (default: $MDT_BACKEND)
      --source-image <IMG>    MayaNAS Lustre image (default: $SOURCE_IMAGE)

  --deploy-client [TYPE]      Also deploy a test client VM and mount Lustre.
                              Optional TYPE = machine type
                              (default: $CLIENT_MACHINE_TYPE)
      --client-image <IMG>    Client boot image (gcloud image spec).
                              Default: ubuntu-os-cloud/ubuntu-2404-lts-amd64
                              Example: rocky-linux-cloud/rocky-linux-10

  -s, --spot                  Use spot / preemptible instances (cheaper)
      --no-public-ip          Deploy storage nodes with no public IPs.
                              Auto-enables Private Google Access on the
                              subnet and IAP tunnel for SSH.
                              (default: public IPs ON for zero-friction eval)

  --skip-deploy               Reuse existing storage cluster (skip its terraform
                              apply). Client --deploy-client still runs
                              terraform apply (idempotent: re-creates if
                              destroyed, no-op if already up).
  --destroy                   Tear down (reverse of deploy)
  -h, --help                  Show this help

Example:
  # Deploy with default client machine type:
  $0 --cloud gcp -b 12 -p mayanas-testing -m c3d-standard-90 \\
     -n lug -z us-central1-f --deploy-client

  # Deploy with custom client machine type:
  $0 --cloud gcp -p mayanas-testing -z us-central1-f \\
     --deploy-client n2-highcpu-48

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
        -n|--cluster-name)     CLUSTER_NAME="$2"; shift 2 ;;
        -m|--machine-type)     MACHINE_TYPE="$2"; shift 2 ;;
        -b|--buckets)          BUCKET_COUNT="$2"; shift 2 ;;
        -t|--deployment-type)  DEPLOYMENT_TYPE="$2"; shift 2 ;;
        --fsname)              FSNAME="$2"; shift 2 ;;
        --mdt-backend)         MDT_BACKEND="$2"; shift 2 ;;
        --source-image)        SOURCE_IMAGE="$2"; shift 2 ;;
        --deploy-client)
            DEPLOY_CLIENT="true"
            # Optional argument: next token is treated as machine type
            # unless it's missing or starts with '-' (another flag).
            if [[ -n "${2:-}" && "$2" != -* ]]; then
                CLIENT_MACHINE_TYPE="$2"
                shift 2
            else
                shift
            fi
            ;;
        --client-machine-type) CLIENT_MACHINE_TYPE="$2"; shift 2 ;;  # alias (kept for back-compat)
        --client-image)        CLIENT_IMAGE="$2"; shift 2 ;;
        -s|--spot)             USE_SPOT="true"; shift ;;
        --no-public-ip)        ASSIGN_PUBLIC_IP="false"; shift ;;
        --skip-deploy)         SKIP_DEPLOY="true"; shift ;;
        --destroy)             DESTROY_MODE="true"; shift ;;
        -h|--help)             usage ;;
        *)                     fail "Unknown option: $1 (run with --help)" ;;
    esac
done

# ---- Validation ---------------------------------------------------------
[ "$CLOUD" = "gcp" ] || fail "Only --cloud gcp is supported currently"
[ -n "$PROJECT_ID" ] || fail "--project-id is required"
[ -n "$ZONE" ]       || fail "--zone is required"
[[ "$FSNAME" =~ ^[a-z][a-z0-9]{0,7}$ ]] || fail "--fsname must be 1-8 lowercase alphanumeric, starting with a letter"

REGION="${ZONE%-*}"
MAYANAS_DIR="$SCRIPT_DIR/gcp/mayanas"
CLIENT_DIR="$SCRIPT_DIR/gcp/client-testing"

[ -d "$MAYANAS_DIR" ] || fail "Expected $MAYANAS_DIR to exist"
command -v terraform >/dev/null || fail "terraform binary not found in PATH"
command -v gcloud    >/dev/null || fail "gcloud binary not found in PATH"

# ---- Banner -------------------------------------------------------------
echo
echo -e "${BOLD}MayaNAS Unified Lustre Data Platform — Deploy${NC}"
echo "  Log:          $LOGFILE"
echo "  Project:      $PROJECT_ID"
echo "  Zone/Region:  $ZONE / $REGION"
echo "  Cluster:      $CLUSTER_NAME"
echo "  Machine:      $MACHINE_TYPE  ·  buckets: $BUCKET_COUNT"
echo "  Deployment:   $DEPLOYMENT_TYPE  ·  fsname: $FSNAME  ·  MDT: $MDT_BACKEND"
echo "  Image:        $SOURCE_IMAGE"
echo "  Spot:         $USE_SPOT  ·  Public IP: $ASSIGN_PUBLIC_IP"
if [ "$DEPLOY_CLIENT" = "true" ]; then
    echo "  Client:       $CLIENT_MACHINE_TYPE"
fi
echo

# ---- Destroy path -------------------------------------------------------
if [ "$DESTROY_MODE" = "true" ]; then
    log "Destroying Lustre deployment... (verbose terraform output → $LOGFILE)"

    if [ -f "$CLIENT_DIR/terraform.tfstate" ]; then
        log "Tearing down client..."
        (cd "$CLIENT_DIR" && terraform destroy -auto-approve -input=false) >> "$LOGFILE" 2>&1 \
            && ok "Client destroyed" \
            || warn "Client destroy had errors — see $LOGFILE"
    fi

    # Storage destroy — try first, fall back to emptying GCS buckets with gsutil
    # if terraform can't remove non-empty buckets cleanly (force_destroy sometimes races).
    log "Tearing down storage cluster..."
    if (cd "$MAYANAS_DIR" && terraform destroy -auto-approve -input=false) >> "$LOGFILE" 2>&1; then
        ok "Storage cluster destroyed"
    else
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

        log "Retrying terraform destroy..."
        (cd "$MAYANAS_DIR" && terraform destroy -auto-approve -input=false) >> "$LOGFILE" 2>&1 \
            && ok "Storage cluster destroyed (after bucket cleanup)" \
            || fail "MayaNAS destroy failed even after bucket cleanup — see $LOGFILE"
    fi

    ok "Teardown complete"
    echo "Log: $LOGFILE"
    exit 0
fi

# ---- Find a usable SSH public key (for client deploy) -------------------
pick_ssh_pubkey() {
    for candidate in \
        "$HOME/.ssh/google_compute_engine.pub" \
        "$HOME/.ssh/id_ed25519.pub" \
        "$HOME/.ssh/id_rsa.pub"; do
        if [ -r "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

# ---- Generate tfvars for mayanas module ---------------------------------
TFVARS="$MAYANAS_DIR/terraform.tfvars"
log "Writing $TFVARS"
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
    (cd "$MAYANAS_DIR" && terraform apply -auto-approve -input=false) 2>&1 | tee -a "$LOGFILE" | grep -E "Apply complete|Error|error" || true
    APPLY_RC=${PIPESTATUS[0]}
    [ "$APPLY_RC" -eq 0 ] || fail "terraform apply failed (exit $APPLY_RC) — see $LOGFILE"

    # Sanity check: Lustre mount command must be resolvable from outputs
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

    # The client module requires ssh_public_key — pick one from the user's keyring.
    SSH_PUBKEY_FILE=$(pick_ssh_pubkey) \
        || fail "No SSH public key found at ~/.ssh/{google_compute_engine,id_ed25519,id_rsa}.pub — create one (ssh-keygen) or skip --deploy-client"
    SSH_PUBKEY=$(cat "$SSH_PUBKEY_FILE")
    log "Using SSH public key: $SSH_PUBKEY_FILE"

    CLIENT_TFVARS="$CLIENT_DIR/terraform.tfvars"
    log "Writing $CLIENT_TFVARS"
    cat > "$CLIENT_TFVARS" <<EOF
project_id     = "$PROJECT_ID"
zone           = "$ZONE"
client_name    = "${CLUSTER_NAME}-client"
machine_type   = "$CLIENT_MACHINE_TYPE"
ssh_public_key = "$SSH_PUBKEY"
use_spot       = $USE_SPOT
EOF
    # Only override source_image if user asked explicitly
    if [ -n "$CLIENT_IMAGE" ]; then
        echo "source_image   = \"$CLIENT_IMAGE\"" >> "$CLIENT_TFVARS"
    fi

    # Client terraform apply is idempotent — no-op if VM already exists, creates
    # if destroyed. Always run it regardless of --skip-deploy (which is for the
    # expensive storage tier only).
    log "Deploying (or reconciling) client VM..."
    (cd "$CLIENT_DIR" && terraform init -input=false) >> "$LOGFILE" 2>&1 || fail "client terraform init failed"
    (cd "$CLIENT_DIR" && terraform apply -auto-approve -input=false) 2>&1 | tee -a "$LOGFILE" | grep -E "Apply complete|Error|error" || true
    CLIENT_RC=${PIPESTATUS[0]}
    [ "$CLIENT_RC" -eq 0 ] || fail "client terraform apply failed (exit $CLIENT_RC) — see $LOGFILE"

    CLIENT_NAME=$(cd "$CLIENT_DIR" && terraform output -raw client_name 2>/dev/null || echo "${CLUSTER_NAME}-client")
    ok "Client $CLIENT_NAME ready"

    # Pick up the admin username from client module output (default: mayanas)
    SSH_USER=$(cd "$CLIENT_DIR" && terraform output -raw ssh_user 2>/dev/null || echo "mayanas")

    # Wait for SSH on the freshly-booted client (can take ~60-90s for cloud-init)
    log "Waiting for client SSH..."
    for attempt in 1 2 3 4 5 6; do
        if gcloud compute ssh "${SSH_USER}@${CLIENT_NAME}" --zone="$ZONE" --project="$PROJECT_ID" \
            --quiet --command="echo ready" >/dev/null 2>&1; then
            break
        fi
        log "  waiting for client SSH (attempt $attempt/6)..."
        sleep 20
    done

    # Push install-lustre-client.sh to the client and run it.
    # install-lustre-client.sh auto-detects OS and uses the right Whamcloud
    # path (DKMS for Rocky, dpkg-x + source build for Ubuntu).
    INSTALLER="$SCRIPT_DIR/install-lustre-client.sh"
    if [ -r "$INSTALLER" ]; then
        log "Copying install-lustre-client.sh to client"
        gcloud compute scp "$INSTALLER" "${SSH_USER}@${CLIENT_NAME}":/tmp/ \
            --zone="$ZONE" --project="$PROJECT_ID" 2>&1 | tee -a "$LOGFILE" | tail -3 || \
            fail "Failed to scp install-lustre-client.sh to client"

        log "Running install-lustre-client.sh on client (5-10 min for build)..."
        gcloud compute ssh "${SSH_USER}@${CLIENT_NAME}" \
            --zone="$ZONE" --project="$PROJECT_ID" --quiet \
            --command="sudo bash /tmp/install-lustre-client.sh" 2>&1 | tee -a "$LOGFILE" | tail -5 || \
            fail "install-lustre-client.sh failed on client — see $LOGFILE"
        ok "Lustre client installed"

        log "Mounting zettafs and verifying..."
        gcloud compute ssh "${SSH_USER}@${CLIENT_NAME}" \
            --zone="$ZONE" --project="$PROJECT_ID" --quiet --command="
                sudo modprobe lustre 2>&1
                sudo mkdir -p /mnt/lustre
                sudo $MOUNT_CMD 2>&1
                echo '--- lfs df ---'
                lfs df -h 2>&1 | head -6
                echo '--- lfs check servers ---'
                lfs check servers 2>&1 | head -5
            " 2>&1 | tee -a "$LOGFILE" | tail -15
        ok "zettafs mounted at /mnt/lustre on $CLIENT_NAME"
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
echo "Connect to node 1 via IAP (no public IP needed):"
echo "  gcloud compute ssh mayanas@$NODE1_NAME --zone=$ZONE --project=$PROJECT_ID --tunnel-through-iap"
echo
echo -e "${BOLD}────────────────────────────────────────────────────────────${NC}"

if [ "$DEPLOY_CLIENT" = "true" ]; then
    # Client already provisioned: Lustre installed and zettafs mounted.
    CLIENT_PUBIP=$(cd "$CLIENT_DIR" && terraform output -raw client_public_ip 2>/dev/null || echo "")
    echo -e "${BOLD}Client VM  —  Lustre installed, zettafs mounted at /mnt/lustre${NC}"
    echo "  Name:    ${CLUSTER_NAME}-client"
    [ -n "$CLIENT_PUBIP" ] && echo "  Public:  $CLIENT_PUBIP"
    echo "  SSH:     gcloud compute ssh ${SSH_USER}@${CLUSTER_NAME}-client --zone=$ZONE --project=$PROJECT_ID"
    echo "  Mount:   $MOUNT_CMD"
    echo
    echo "Verify on the client:"
    echo "  gcloud compute ssh ${SSH_USER}@${CLUSTER_NAME}-client --zone=$ZONE --project=$PROJECT_ID --command='lfs df -h; lfs check servers'"
else
    # No client VM — show BYO-client instructions.
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
echo "  $0 --cloud $CLOUD -p $PROJECT_ID -z $ZONE -n $CLUSTER_NAME --destroy"
echo
echo "Log: $LOGFILE"
