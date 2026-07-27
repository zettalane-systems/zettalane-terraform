#!/bin/bash
# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

#
# csi-client-setup.sh — install the ZettaLane CSI driver on a fresh Kubernetes
# client against a live MayaNAS (file/NFS) or MayaScale (block/nvme-of) cluster.
#
# SETUP ONLY: installs jq/k3s/helm (+ nvme-tcp for block), imports the driver
# image, and `helm install`s the driver. It does NOT create StorageClasses, PVCs,
# or run any I/O. To exercise the driver afterwards, run csi-fio-test.sh (which
# owns its own StorageClass/PVC/fio fixtures).
#
# ONE image serves BOTH products; the instance is selected by the `driver` field
# of the cluster's `csi_backend` Terraform output, consumed verbatim here.
#
# Typical use (on the client VM, which must sit inside the cluster's VPC):
#
#     # on the box with the Terraform state:
#     terraform -chdir=gcp/mayascale output -json csi_backend > backend.json
#     scp backend.json <client>:~/
#     # on the client -- PUBLIC (self-contained from ghcr, no --image):
#     sudo ./csi-client-setup.sh --backend-json ~/backend.json
#     sudo ./csi-fio-test.sh     --backend-json ~/backend.json        # then test
#
# INTERNAL / dev testing -- pin a specific image (tar import or registry pull):
#     sudo ./csi-client-setup.sh --backend-json ~/backend.json --image-tar ~/img.tar
#     sudo ./csi-client-setup.sh --backend-json ~/backend.json \
#          --image ghcr.io/zettalane-systems/zettalane-csi:1.0.6
#
# Run as root (sudo). Idempotent / re-runnable.
#
set -euo pipefail

log()  { echo "[csi-client-setup] $*"; }
fail() { echo "[csi-client-setup] ERROR: $*" >&2; exit 1; }

# ---- defaults / args -------------------------------------------------------
BACKEND_JSON=""
IMAGE_TAR=""
IMAGE_REF="localhost/zettalane-csi:dev"   # ref used in the Helm values
IMAGE_EXPLICIT=0                            # set when --image is passed (don't override from the tar)
CLEANUP=0
CHART=""                                   # override: .tgz | oci:// ref | http(s) URL | dir
CHART_OCI="oci://ghcr.io/zettalane-systems/charts/zettalane-csi"  # ghcr = source of truth
CHART_VERSION="1.0.0"                       # default chart version to fetch
NS="zettalane-csi"

usage() {
    cat >&2 <<EOF
Usage: sudo $0 --backend-json <file> [--image-tar <path> | --image <ref>] [options]

  --backend-json <file>  JSON from: terraform output -json csi_backend   (required)
  --image-tar <path|url> 'podman save' tar to import into k3s containerd; accepts a
                         local path OR an http(s) URL (e.g. the published zettalane.com tar)
  --image <ref>          registry image ref to pull instead of importing a tar
  --chart <ref>          zettalane-csi chart: .tgz | oci:// ref | http(s) URL | dir
                         (default: ${CHART_OCI} version ${CHART_VERSION})
  --cleanup              uninstall the driver (helm release + namespace) and exit
  -h, --help             this help

With no --image-tar/--image, the image + chart pull from public ghcr
(self-contained). Pass --image-tar/--image to pin a dev/specific image.
Setup only; run csi-fio-test.sh to exercise the driver.
EOF
    exit "${1:-2}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --backend-json) BACKEND_JSON="$2"; shift 2 ;;
        --image-tar)    IMAGE_TAR="$2";    shift 2 ;;
        --image)        IMAGE_REF="$2"; IMAGE_EXPLICIT=1; shift 2 ;;
        --chart)        CHART="$2";        shift 2 ;;
        --chart-version)CHART_VERSION="$2";shift 2 ;;
        --cleanup)      CLEANUP=1;         shift ;;
        -h|--help)      usage 0 ;;
        *) fail "unknown argument: $1 (try --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || fail "Must run as root (sudo)"
[ -n "$BACKEND_JSON" ] || usage
[ -f "$BACKEND_JSON" ] || fail "backend JSON not found: $BACKEND_JSON"

. /etc/os-release

# ---- prerequisites: jq, k3s, helm ------------------------------------------
ensure_pkg() {
    # ensure_pkg <command> <deb-pkg> <rpm-pkg>
    command -v "$1" >/dev/null && return 0
    log "installing $1"
    case "$ID" in
        ubuntu|debian) apt-get update -qq && apt-get install -y "$2" ;;
        rocky|rhel|almalinux|centos) dnf install -y "$3" ;;
        *) fail "unsupported OS for auto-install: $ID (install $1 manually)" ;;
    esac
}

ensure_pkg jq jq jq

if ! command -v k3s >/dev/null; then
    log "installing k3s (single-node, kubeconfig mode 644)"
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K="k3s kubectl"
$K get nodes >/dev/null 2>&1 || fail "k3s not Ready (check 'systemctl status k3s')"

if ! command -v helm >/dev/null; then
    log "installing helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ---- parse the backend handoff ---------------------------------------------
DRIVER=$(jq -r '.driver' "$BACKEND_JSON")
[ "$DRIVER" = "null" ] || [ -z "$DRIVER" ] && fail "csi_backend.driver missing"
case "$DRIVER" in
    mayanas|mayascale|mayanas-lustre) : ;;
    *) fail "unsupported driver in csi_backend: $DRIVER" ;;
esac
# The cluster VIP list lives under a key named for the driver (.mayanas/.mayascale).
VIPLIST=$(jq -r --arg d "$DRIVER" '.[$d]' "$BACKEND_JSON")
[ "$VIPLIST" = "null" ] || [ -z "$VIPLIST" ] && fail "csi_backend.$DRIVER (VIP list) missing"

RELEASE="csi-$DRIVER"

log "driver=$DRIVER  control VIP list=$VIPLIST"

# ---- cleanup mode ----------------------------------------------------------
if [ "$CLEANUP" -eq 1 ]; then
    log "uninstalling driver release '$RELEASE'"
    helm -n "$NS" uninstall "$RELEASE" 2>/dev/null || true
    $K delete ns "$NS" --ignore-not-found 2>/dev/null || true
    log "done (run csi-fio-test.sh --cleanup first if test PVCs remain)"
    exit 0
fi

# ---- image: import tar (local path OR http(s) URL) OR rely on registry pull -
# --image-tar accepts a published URL too (e.g. the zettalane.com image tar),
# mirroring --chart: an http(s) value is downloaded then imported. The imported
# image is tagged localhost/zettalane-csi:dev (the save-time ref), which is what
# the default IMAGE_REF in the Helm values expects -- so no --image needed.
if [ -n "$IMAGE_TAR" ]; then
    _IMG_DL=""
    case "$IMAGE_TAR" in
        http://*|https://*)
            _IMG_DL=$(mktemp /tmp/zettalane-csi-img.XXXXXX.tar)
            log "downloading image tar: $IMAGE_TAR"
            curl -fSL --retry 3 -o "$_IMG_DL" "$IMAGE_TAR" || fail "image tar download failed: $IMAGE_TAR"
            IMAGE_TAR="$_IMG_DL"
            ;;
    esac
    [ -f "$IMAGE_TAR" ] || fail "image tar not found: $IMAGE_TAR"
    # Derive the Helm image ref from THE TAR'S OWN manifest (RepoTags) -- unless --image
    # was explicit. This is authoritative and tag-stable: a release tar is tagged
    # :<version> (e.g. :1.0.1), not :dev, and the ref must match exactly what containerd
    # holds (pullPolicy IfNotPresent) or pods ImagePullBackOff "not found". Reading the
    # tar (not `images ls | head -1`) avoids picking a STALE/other zettalane-csi tag that
    # is already in containerd from a previous import.
    if [ "$IMAGE_EXPLICIT" -ne 1 ]; then
        DERIVED_REF=$(tar xOf "$IMAGE_TAR" manifest.json 2>/dev/null | grep -oE '[A-Za-z0-9._/-]*zettalane-csi:[A-Za-z0-9._-]+' | head -1)
        [ -n "$DERIVED_REF" ] && IMAGE_REF="$DERIVED_REF"
        log "image ref from tar manifest: $IMAGE_REF"
    fi
    log "importing image into k3s containerd: $IMAGE_TAR"
    k3s ctr images import "$IMAGE_TAR"
    [ -n "$_IMG_DL" ] && rm -f "$_IMG_DL"
fi
# no --image-tar/--image: use the chart's default ghcr image (self-contained)
# Image override is emitted into the Helm values ONLY when an image was given
# (--image-tar or --image). Chart-only -> leave it out so the chart's default
# driver image (ghcr.io/zettalane-systems/zettalane-csi:latest) stands. ${IMGKV}
# is a leading-comma flow-map fragment spliced into `driver: { ... }`.
if [ -n "$IMAGE_TAR" ] || [ "$IMAGE_EXPLICIT" -eq 1 ]; then
    IMG_REGISTRY="${IMAGE_REF%:*}"; IMG_TAG="${IMAGE_REF##*:}"
    IMGKV=", image: { registry: ${IMG_REGISTRY}, tag: ${IMG_TAG}, pullPolicy: IfNotPresent }"
    log "image override: registry=$IMG_REGISTRY tag=$IMG_TAG"
else
    IMGKV=""
    log "no --image/--image-tar -> using chart default image (ghcr.io/.../zettalane-csi:latest)"
fi

# ---- block (mayascale) node PRE-FLIGHT: nvme-tcp transport + nvme-cli -------
# The client images (terraform client-testing cloud-init) install ONLY nfs-common
# + fio -- NOT any nvme bits. So for the block driver this preflight is REQUIRED,
# and it verifies the END STATE (not just "ran the install"), failing early with an
# actionable message rather than letting the node DaemonSet hang later.
#   1. nvme-tcp kernel transport  -> NodeStage `nvme connect` needs it.
#   2. nvme-cli package on the HOST -> its postinst creates /etc/nvme/hostnqn+hostid,
#      which the node plugin hostPath-mounts (type: Directory, must pre-exist) for a
#      stable per-NODE NVMe host identity. Missing => node pod stuck ContainerCreating
#      ("hostPath type check failed: /etc/nvme is not a directory") => driver never
#      registers => PVCs Bind but pods stay Pending. (nvme connect runs IN the image.)
if [ "$DRIVER" = "mayascale" ]; then
    log "block pre-flight: verifying nvme-tcp transport + nvme-cli host identity"
    # (1) nvme-tcp transport
    if ! modprobe nvme-tcp 2>/dev/null; then
        log "  nvme-tcp not loadable -- installing kernel modules"
        case "$ID" in
            ubuntu|debian) apt-get install -y "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || true ;;
            rocky|rhel|almalinux|centos) : ;;  # el9 ships nvme-tcp in the base kernel
        esac
        modprobe nvme-tcp 2>/dev/null || true
    fi
    grep -qw nvme_tcp /proc/modules || fail "nvme-tcp transport not available (modprobe nvme-tcp failed) -- install linux-modules-extra-$(uname -r) and retry"
    # (2) nvme-cli on the host (-> /etc/nvme/hostnqn via postinst)
    ensure_pkg nvme nvme-cli nvme-cli
    command -v nvme >/dev/null || fail "nvme-cli not installed (no 'nvme' binary) -- install it and retry"
    # (3) host identity dir/files: package postinst should have made them; backstop
    #     with nvme-cli's own generators (NEVER hand-craft). Required for the mount.
    [ -f /etc/nvme/hostnqn ] || { mkdir -p /etc/nvme && nvme gen-hostnqn > /etc/nvme/hostnqn; }
    [ -f /etc/nvme/hostid ]  || nvme gen-hostid 2>/dev/null > /etc/nvme/hostid || cat /proc/sys/kernel/random/uuid > /etc/nvme/hostid
    [ -s /etc/nvme/hostnqn ] || fail "/etc/nvme/hostnqn missing/empty -- node plugin hostPath mount will fail"
    log "block pre-flight OK: nvme_tcp loaded, nvme-cli present, host nqn $(cat /etc/nvme/hostnqn)"
fi

# ---- k3s auth for a private GCP Artifact Registry image --------------------
# k3s/containerd needs registry creds to pull from AR. When --image is an AR ref
# (*-docker.pkg.dev), fetch a FRESH metadata access-token (the client SA needs
# roles/artifactregistry.reader + the cloud-platform scope -- granted by the
# terraform client module) and write registries.yaml right before the pull, so
# the token is never stale. GKE auto-authenticates, so this is k3s-only.
case "$IMAGE_REF" in
  *-docker.pkg.dev/*)
    AR_HOST="${IMAGE_REF%%/*}"
    log "Artifact Registry image -> configuring k3s pull auth for $AR_HOST"
    AR_TOKEN=$(curl -s -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])' 2>/dev/null || true)
    if [ -n "$AR_TOKEN" ]; then
      mkdir -p /etc/rancher/k3s
      cat > /etc/rancher/k3s/registries.yaml <<EOF
configs:
  "$AR_HOST":
    auth:
      username: oauth2accesstoken
      password: "$AR_TOKEN"
EOF
      systemctl restart k3s
      for _ in $(seq 1 25); do $K get nodes >/dev/null 2>&1 && break; sleep 3; done
      log "AR pull auth set (registries.yaml) + k3s restarted"
    else
      log "WARN: no metadata token for AR auth -- pull may 401 (check SA artifactregistry.reader + cloud-platform scope)"
    fi
    ;;
esac

# ---- generate Helm values + deploy (driver only, no StorageClasses) --------
VALUES=$(mktemp /tmp/values-${DRIVER}.XXXXXX.yaml)
trap 'rm -f "$VALUES"' EXIT

if [ "$DRIVER" = "mayascale" ]; then
    # block / nvme-of: no hostNetwork (pod egress SNATs to the data VIPs). Pools
    # are discovered from the VIP list; no pinned pool map needed.
    cat > "$VALUES" <<EOF
fullnameOverride: ${RELEASE}
csiDriver: { name: csi-mayascale.zettalane.com, attachRequired: false }
controller:
  hostNetwork: false
  externalAttacher:    { enabled: false }
  externalSnapshotter: { enabled: false }
  externalResizer:     { enabled: true }
  externalProvisioner: { enabled: true }
  driver: { enabled: true${IMGKV} }
node:
  driver: { enabled: true${IMGKV} }
storageClasses: []
driver:
  config:
    driver: mayascale
    mayascale: "${VIPLIST}"
EOF
else
    # file / NFS: hostNetwork so configd's hosts.allow sees the node IP. Pin ALL
    # pools (clusterid+vip) so csi-fio-test.sh can target any of them.
    POOLS_YAML=$(jq -r '.pools | to_entries[] | "      \(.key): { clusterid: \(.value.clusterid), vip: \"\(.value.vip)\" }"' "$BACKEND_JSON")
    cat > "$VALUES" <<EOF
fullnameOverride: ${RELEASE}
csiDriver: { name: csi-mayanas.zettalane.com, attachRequired: false }
controller:
  hostNetwork: true
  externalAttacher:    { enabled: false }
  externalSnapshotter: { enabled: false }
  externalResizer:     { enabled: true }
  externalProvisioner: { enabled: true }
  driver: { enabled: true${IMGKV} }
node:
  driver: { enabled: true${IMGKV} }
storageClasses: []
driver:
  config:
    driver: mayanas
    mayanas: "${VIPLIST}"
    pools:
${POOLS_YAML}
EOF
fi

# Our OWN zettalane-csi chart (decision B) -- NOT the upstream democratic-csi
# chart. Default: the OCI chart on ghcr (the source of truth). Override with
# --chart (local .tgz, another oci:// ref, dir, or http(s) URL).
if [ -z "$CHART" ]; then
    CHART="${CHART_OCI}"
fi
# OCI charts are versioned via --version (the ref carries no version); a tgz/dir/URL
# already pins it. So pass --version only for oci:// refs.
HELM_VER_ARG=()
case "$CHART" in oci://*) HELM_VER_ARG=(--version "$CHART_VERSION") ;; esac
log "deploying Helm release '$RELEASE' (chart: $CHART${HELM_VER_ARG:+ version $CHART_VERSION})"
helm upgrade --install "$RELEASE" "$CHART" "${HELM_VER_ARG[@]}" \
    -n "$NS" --create-namespace -f "$VALUES"

log "waiting for controller rollout"
$K -n "$NS" rollout status "deploy/${RELEASE}-controller" --timeout=180s

echo
log "driver '$RELEASE' is up. No StorageClass/PVC created (setup only)."
log "Exercise it:  sudo ./csi-fio-test.sh --backend-json $BACKEND_JSON"
log "Remove it:    sudo $0 --backend-json $BACKEND_JSON --cleanup"
