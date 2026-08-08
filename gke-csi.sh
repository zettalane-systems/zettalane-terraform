#!/usr/bin/env bash
#
# gke-csi.sh — create a GKE cluster and deploy the ZettaLane CSI driver,
# pulling the image from Artifact Registry and the chart from its URL.
#
# Why GKE (vs the k3s client): GKE nodes auto-authenticate to Artifact Registry
# via the node SA, so the image pulls with NO registries.yaml/token. GKE also
# ships the VolumeSnapshot CRDs, so the snapshot path is testable. Ubuntu node
# pool so nvme_tcp is available for the block data path (nvme connect).
#
# The GKE cluster must sit in the SAME VPC as the storage nodes (default) so the
# CSI pods can reach the 10.100.198.x data VIPs (configd hosts.allow admits VPC
# peers; pods SNAT to the node).
#
# Usage: gke-csi.sh --backend-json <file> [options]
#   --backend-json <file>  csi_backend.json (driver + VIP list + pools)   [required
#                          unless --create-only]
#   --create-only          build the CLUSTER, then stop -- no driver. On a greenfield
#                          deploy there is no storage yet, so there are no endpoints to
#                          point a driver at; the deployer installs it afterwards.
#   --zone/--project/--machine-type    override the defaults below
#   --image <ref>          CSI image (default: AR <region>-docker.pkg.dev/<proj>/zettalane/zettalane-csi:<ver>)
#   --chart <ref>          chart .tgz | oci:// | http(s) URL
#                          (default: https://zettalane.com/mayanas/csi/zettalane-csi-<ver>.tgz)
#   --cluster <name>       GKE cluster name (default: zettalane-csi-gke)
#   --nodes  N             node pool size (default: 3)
#   --spot                 spot/preemptible nodes (cheaper; fine for the CSI test side, not storage)
#   --cleanup              helm uninstall + delete the GKE cluster, then exit
# Env: PROJECT (default mayanas-testing), ZONE (us-central1-a), NETWORK (default),
#      MACHINE_TYPE (e2-standard-4), CHART_VERSION (1.0.0)

set -euo pipefail
log()  { echo "[gke-csi] $*"; }
fail() { echo "[gke-csi] ERROR: $*" >&2; exit 1; }

BACKEND_JSON=""; CLEANUP=0; CREATE_ONLY=0
# See aks-csi.sh: only a deployer-created cluster carries the deployment stamp that
# makes it disposable. One you create by hand is never deleted by --destroy.
OWNER_DEPLOYMENT="${OWNER_DEPLOYMENT:-}"
NO_CREATE=0   # refuse to create; the caller says a cluster already exists
CLUSTER="${CLUSTER:-zettalane-csi-gke}"
NODES="${NODES:-3}"
PROJECT="${PROJECT:-mayanas-testing}"
ZONE="${ZONE:-us-central1-a}"
NETWORK="${NETWORK:-default}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
CHART_VERSION="${CHART_VERSION:-1.0.0}"
REGION="${ZONE%-*}"
# One source of truth for the driver image (see csi-version.env). This used to default
# to OUR Artifact Registry (mayanas-testing), which no customer can pull, AND took its
# tag from CHART_VERSION -- chart and image version are NOT the same thing, so gke ran
# a 1.0.0 driver while k3s and aks ran 1.0.6.
_CSI_ENV="$(dirname "$0")/csi-version.env"
[ -r "$_CSI_ENV" ] && . "$_CSI_ENV"
IMAGE_REF="${IMAGE_REF:-${CSI_IMAGE_REGISTRY:-ghcr.io/zettalane-systems}/zettalane-csi:${CSI_IMAGE_VERSION:-1.0.6}}"
CHART="${CHART:-https://zettalane.com/mayanas/csi/zettalane-csi-${CHART_VERSION}.tgz}"
NS="zettalane-csi"
SPOT=""   # --spot: GKE spot/preemptible nodes (cheaper; OK for the CSI test side -- not storage)

while [ $# -gt 0 ]; do
  case "$1" in
    --backend-json) BACKEND_JSON="$2"; shift 2 ;;
    --image)        IMAGE_REF="$2";    shift 2 ;;
    --chart)        CHART="$2";        shift 2 ;;
    --cluster)      CLUSTER="$2";      shift 2 ;;
    --zone)         ZONE="$2";         shift 2 ;;
    --project)      PROJECT="$2";      shift 2 ;;
    --machine-type) MACHINE_TYPE="$2"; shift 2 ;;
    --create-only)  CREATE_ONLY=1;     shift ;;
    --no-create)    NO_CREATE=1;       shift ;;
    --owner)        OWNER_DEPLOYMENT="$2"; shift 2 ;;
    --nodes)        NODES="$2";        shift 2 ;;
    --spot)         SPOT=1;            shift ;;
    --cleanup)      CLEANUP=1;         shift ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown arg: $1 (try --help)" ;;
  esac
done

for t in gcloud kubectl helm jq; do command -v "$t" >/dev/null || fail "'$t' not on PATH"; done

# ---- cleanup ---------------------------------------------------------------
if [ "$CLEANUP" -eq 1 ]; then
  if gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT" 2>/dev/null; then
    helm -n "$NS" uninstall "csi-mayascale" 2>/dev/null || true
    helm -n "$NS" uninstall "csi-mayanas"   2>/dev/null || true
  fi
  log "deleting GKE cluster $CLUSTER (zone $ZONE)"
  gcloud container clusters delete "$CLUSTER" --zone "$ZONE" --project "$PROJECT" --quiet
  exit 0
fi

if [ "$CREATE_ONLY" = 1 ]; then
  log "create-only: cluster only, no driver (no storage endpoints exist yet)"
else
[ -n "$BACKEND_JSON" ] && [ -f "$BACKEND_JSON" ] || fail "--backend-json <file> is required"
DRIVER=$(jq -r '.driver' "$BACKEND_JSON")
case "$DRIVER" in mayascale|mayanas|mayanas-lustre) : ;; *) fail "bad driver in backend: $DRIVER" ;; esac
VIPLIST=$(jq -r --arg d "$DRIVER" '.[$d]' "$BACKEND_JSON")
[ -n "$VIPLIST" ] && [ "$VIPLIST" != "null" ] || fail "csi_backend.$DRIVER (VIP list) missing"
RELEASE="csi-$DRIVER"
IMG_REGISTRY="${IMAGE_REF%:*}"; IMG_TAG="${IMAGE_REF##*:}"
log "driver=$DRIVER  VIPs=$VIPLIST  image=$IMAGE_REF  chart=$CHART"
fi

# ---- create the GKE cluster (Ubuntu nodes, same VPC) ----------------------
if gcloud container clusters describe "$CLUSTER" --zone "$ZONE" --project "$PROJECT" >/dev/null 2>&1; then
  log "GKE cluster $CLUSTER already exists"
elif [ "$NO_CREATE" = 1 ]; then
  fail "no GKE cluster $CLUSTER in zone $ZONE (project $PROJECT) -- refusing to create one.
       Check --zone/--project: a wrong zone here builds a DUPLICATE cluster of the same name."
else
  log "creating GKE cluster $CLUSTER ($NODES x $MACHINE_TYPE${SPOT:+ spot}, Ubuntu, net=$NETWORK)"
  gcloud container clusters create "$CLUSTER" \
    --project "$PROJECT" --zone "$ZONE" \
    --num-nodes "$NODES" --machine-type "$MACHINE_TYPE" \
    --image-type UBUNTU_CONTAINERD \
    --network "$NETWORK" --subnetwork "$NETWORK" \
    --no-enable-basic-auth ${SPOT:+--spot} --quiet \
    --labels zettalane-created=true${OWNER_DEPLOYMENT:+,zettalane-deployment=$OWNER_DEPLOYMENT}
fi
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT"
# Stop here on --create-only: the driver install needs storage that does not exist yet.
[ "$CREATE_ONLY" = 1 ] && { log "cluster $CLUSTER ready (zone $ZONE, net=$NETWORK)"; exit 0; }

# ---- helm values (snapshots ON; AR image; nvme dir mount) -----------------
VALUES=$(mktemp /tmp/gke-values-${DRIVER}.XXXXXX.yaml)
trap 'rm -f "$VALUES"' EXIT
if [ "$DRIVER" = "mayascale" ]; then
  cat > "$VALUES" <<EOF
fullnameOverride: ${RELEASE}
csiDriver: { name: csi-mayascale.zettalane.com, attachRequired: false }
controller:
  hostNetwork: true              # GKE: pod-IP egress to 10.100.198.x VIPs isn't SNAT'd (ip-masq skips RFC1918) -> use node netns. (node DaemonSet is already hostNetwork:true by chart default.)
  priorityClassName: ""          # GKE gke-resource-quotas blocks system-*-critical outside kube-system
  externalAttacher:    { enabled: false }
  externalSnapshotter: { enabled: true }
  externalResizer:     { enabled: true }
  externalProvisioner: { enabled: true }
  driver: { image: { registry: ${IMG_REGISTRY}, tag: ${IMG_TAG}, pullPolicy: IfNotPresent } }
node:
  priorityClassName: ""
  driver:
    image: { registry: ${IMG_REGISTRY}, tag: ${IMG_TAG}, pullPolicy: IfNotPresent }
    nvmeDirMountEnabled: true
storageClasses: []
driver:
  config:
    driver: mayascale
    mayascale: "${VIPLIST}"
EOF
else
  POOLS_YAML=$(jq -r '.pools | to_entries[] | "      \(.key): { clusterid: \(.value.clusterid), vip: \"\(.value.vip)\" }"' "$BACKEND_JSON")
  cat > "$VALUES" <<EOF
fullnameOverride: ${RELEASE}
csiDriver: { name: csi-mayanas.zettalane.com, attachRequired: false }
controller:
  hostNetwork: true
  priorityClassName: ""          # GKE gke-resource-quotas blocks system-*-critical outside kube-system
  externalAttacher:    { enabled: false }
  externalSnapshotter: { enabled: true }
  externalResizer:     { enabled: true }
  externalProvisioner: { enabled: true }
  driver: { image: { registry: ${IMG_REGISTRY}, tag: ${IMG_TAG}, pullPolicy: IfNotPresent } }
node:
  priorityClassName: ""
  driver: { image: { registry: ${IMG_REGISTRY}, tag: ${IMG_TAG}, pullPolicy: IfNotPresent } }
storageClasses: []
driver:
  config:
    driver: mayanas
    mayanas: "${VIPLIST}"
    pools:
${POOLS_YAML}
EOF
fi

# ---- deploy ----------------------------------------------------------------
log "deploying $RELEASE -> ns/$NS (chart from $CHART)"
helm upgrade --install "$RELEASE" "$CHART" -n "$NS" --create-namespace -f "$VALUES"
kubectl -n "$NS" rollout status "deploy/${RELEASE}-controller" --timeout=240s

echo
log "driver '$RELEASE' is up on GKE cluster '$CLUSTER'. Pods:"
kubectl -n "$NS" get pods -o wide
log "image pulled from AR (GKE node SA auto-auth). Exercise: kubectl apply a PVC on an nvme-of StorageClass."
log "Cleanup: $0 --backend-json $BACKEND_JSON --cleanup   (deletes the cluster)"
