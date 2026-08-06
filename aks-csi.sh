#!/usr/bin/env bash
#
# aks-csi.sh — create an AKS cluster and deploy the ZettaLane CSI driver,
# pulling the image from ACR and the chart from its URL.
#
# Why AKS is the easiest managed target:
#   * Azure CNI (node-subnet) gives every pod a real, routable VNet IP -> the
#     controller talks to the storage data VIPs DIRECTLY. No `hostNetwork: true`,
#     no priorityClassName override (those are GKE-only workarounds).
#   * AKS ships the VolumeSnapshot CRDs + snapshot-controller (managed), so the
#     snapshot/clone path works with no extra install (unlike EKS).
#   * `az aks update --attach-acr` gives the kubelet managed identity AcrPull ->
#     image auto-pull with no pull secret (the ACR analog of ECR/AR node auth).
#
# Azure wrinkle this script handles: the data VIPs (e.g. 10.0.100.x) live OUTSIDE
# any subnet CIDR and are reached via a user-defined route table (UDR) whose next
# hops are the storage node NICs. The k3s client reaches them because its subnet
# has that route table; the AKS node subnet needs the SAME association. So we
# create a dedicated AKS subnet in the storage VNet and associate the storage
# route table (--route-table) with it.
#
# Usage: aks-csi.sh --backend-json <file> [options]
#   --backend-json <file>  csi_backend.json (driver + VIP list + pools)   [required]
#   --image <ref>          CSI image (default: PUBLIC ghcr.io/zettalane-systems/zettalane-csi:<ver>)
#   --chart <ref>          chart .tgz | oci:// | http(s) URL
#                          (default: oci://ghcr.io/zettalane-systems/charts/zettalane-csi)
#   --cluster <name>       AKS cluster name (default: zettalane-csi-aks)
#   --acr <name>           OPTIONAL: attach an ACR + pull the image from it instead of
#                          public ghcr (image must already be pushed there)
#   --nodes  N             node pool size (default: 2)
#   --node-type <size>     VM size (default: Standard_D4s_v5)
#   --zone <z>             AZ to pin nodes to (default: none -- westus has no zones)
#   --spot                 spot node pool (cheaper; fine for the CSI test side)
#   --cleanup              helm uninstall + `az aks delete`, then exit
# Env (defaults target the running csitest3 storage cluster):
#   SUBSCRIPTION (6aa9a5b8-...), RG (mayanas-testing), LOCATION (westus),
#   VNET (mayascale-vnet), AKS_SUBNET (aks-csi-subnet), AKS_SUBNET_CIDR
#   (10.0.20.0/24), ROUTE_TABLE (mayanas-route-table), CHART_VERSION (1.0.0),
#   IMAGE_VERSION (1.0.1)

set -euo pipefail
log()  { echo "[aks-csi] $*"; }
fail() { echo "[aks-csi] ERROR: $*" >&2; exit 1; }

# Find the storage front-end NSG = the one carrying the NVMeoF-TCP rule.
derive_storage_nsg() {
  local nsg
  for nsg in $(az network nsg list -g "$RG" --query "[].name" -o tsv 2>/dev/null); do
    if az network nsg rule show -g "$RG" --nsg-name "$nsg" -n NVMeoF-TCP >/dev/null 2>&1; then
      echo "$nsg"; return 0
    fi
  done
  return 1
}

BACKEND_JSON=""; CLEANUP=0
CLUSTER="${CLUSTER:-zettalane-csi-aks}"
ACR="${ACR:-}"
NODES="${NODES:-2}"
NODE_TYPE="${NODE_TYPE:-Standard_D4s_v3}"
ZONE="${ZONE:-}"                       # westus has no zones -> empty
SPOT=""
# Defaults come from YOUR az context, not from ours. This script ships in a public repo;
# a hardcoded subscription/RG would point a customer's run at somebody else's tenant.
SUBSCRIPTION="${SUBSCRIPTION:-$(az account show --query id -o tsv 2>/dev/null)}"
RG="${RG:-}"
LOCATION="${LOCATION:-}"
VNET="${VNET:-mayascale-vnet}"
AKS_SUBNET="${AKS_SUBNET:-aks-csi-subnet}"
AKS_SUBNET_CIDR="${AKS_SUBNET_CIDR:-10.0.20.0/24}"
ROUTE_TABLE="${ROUTE_TABLE:-mayanas-route-table}"
[ -n "$SUBSCRIPTION" ] || { echo "SUBSCRIPTION not set and 'az account show' gave nothing -- run 'az login'" >&2; exit 2; }
[ -n "$RG" ] || { echo "RG=<resource-group> required (the storage deployment's RG)" >&2; exit 2; }
[ -n "$LOCATION" ] || LOCATION=$(az group show -n "$RG" --subscription "$SUBSCRIPTION" --query location -o tsv 2>/dev/null)
[ -n "$LOCATION" ] || { echo "LOCATION not set and could not be read from RG $RG" >&2; exit 2; }
# The storage NSG gates the NVMeoF data/discovery ports to var.allowed_nvmeof_cidrs
# (default = the storage subnet) -- they are NOT world-exposed. Since we put AKS in
# its own subnet, the script opens that NSG for AKS_SUBNET_CIDR. STORAGE_NSG is
# auto-derived (the NSG carrying the NVMeoF-TCP rule) unless set. Ports cover the
# per-volume data range + discovery. OPEN_NSG=0 to skip (e.g. you used terraform's
# allowed_nvmeof_cidrs instead).
STORAGE_NSG="${STORAGE_NSG:-}"
# Client-facing nvme-of ports only: the per-PVC portals configd auto-allocates
# from 4430 up (one per volume). The driver connects straight to each portal
# (nvme connect -s <portalPort>) -- no 4420 discovery, and 8009 discovery is
# backend-internal -- so neither is opened.
NVMEOF_PORTS="${NVMEOF_PORTS:-4430-4500}"
OPEN_NSG="${OPEN_NSG:-1}"
# K8s service (ClusterIP) range — cluster-internal, must NOT overlap the storage
# VNet (10.0.0.0/16). Kept off-10.x so it can't collide with VIPs/pods/nodes.
SERVICE_CIDR="${SERVICE_CIDR:-192.168.100.0/24}"
DNS_SERVICE_IP="${DNS_SERVICE_IP:-192.168.100.10}"
# Chart and image are versioned INDEPENDENTLY: the chart tracks its own line
# (published 1.0.0), the image tracks the driver build (1.0.11).
CHART_VERSION="${CHART_VERSION:-1.0.0}"
IMAGE_VERSION="${IMAGE_VERSION:-1.0.1}"
NS="zettalane-csi"

while [ $# -gt 0 ]; do
  case "$1" in
    --backend-json) BACKEND_JSON="$2"; shift 2 ;;
    --image)        IMAGE_REF="$2";    shift 2 ;;
    --chart)        CHART="$2";        shift 2 ;;
    --cluster)      CLUSTER="$2";      shift 2 ;;
    --acr)          ACR="$2";          shift 2 ;;
    --nodes)        NODES="$2";        shift 2 ;;
    --node-type)    NODE_TYPE="$2";    shift 2 ;;
    --zone)         ZONE="$2";         shift 2 ;;
    --storage-nsg)  STORAGE_NSG="$2";  shift 2 ;;
    --no-open-nsg)  OPEN_NSG=0;        shift ;;
    --spot)         SPOT=1;            shift ;;
    --cleanup)      CLEANUP=1;         shift ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown arg: $1 (try --help)" ;;
  esac
done

for t in az kubectl helm jq; do command -v "$t" >/dev/null || fail "'$t' not on PATH"; done
az account set --subscription "$SUBSCRIPTION" || fail "cannot set subscription $SUBSCRIPTION"

# Default to PUBLIC ghcr (self-contained, no registry setup). --acr overrides to an
# ACR ref (and attaches it); --image overrides explicitly. --chart defaults to the
# ghcr OCI chart.
IMAGE_REF="${IMAGE_REF:-${ACR:+${ACR}.azurecr.io/zettalane-csi:${IMAGE_VERSION}}}"
IMAGE_REF="${IMAGE_REF:-ghcr.io/zettalane-systems/zettalane-csi:${IMAGE_VERSION}}"
CHART="${CHART:-oci://ghcr.io/zettalane-systems/charts/zettalane-csi}"

# ---- cleanup ---------------------------------------------------------------
if [ "$CLEANUP" -eq 1 ]; then
  if az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing 2>/dev/null; then
    helm -n "$NS" uninstall "csi-mayascale" 2>/dev/null || true
    helm -n "$NS" uninstall "csi-mayanas"   2>/dev/null || true
  fi
  log "deleting AKS cluster $CLUSTER (rg $RG)"
  az aks delete -g "$RG" -n "$CLUSTER" --yes
  # revoke the NVMeoF allow we added for the AKS subnet
  RULE="Allow-NVMeoF-$(echo "$AKS_SUBNET_CIDR" | tr './' '--')"
  NSG="${STORAGE_NSG:-$(derive_storage_nsg || true)}"
  [ -n "$NSG" ] && { log "removing NSG rule $RULE from $NSG"; \
    az network nsg rule delete -g "$RG" --nsg-name "$NSG" -n "$RULE" 2>/dev/null || true; }
  log "leaving subnet '$AKS_SUBNET' + its route-table assoc in place (delete by hand if done)"
  exit 0
fi

[ -n "$BACKEND_JSON" ] && [ -f "$BACKEND_JSON" ] || fail "--backend-json <file> is required"
[ -n "$IMAGE_REF" ] || fail "no image: pass --acr <name> (image pushed there) or --image <ref>"
DRIVER=$(jq -r '.driver' "$BACKEND_JSON")
case "$DRIVER" in mayascale|mayanas|mayanas-lustre) : ;; *) fail "bad driver in backend: $DRIVER" ;; esac
VIPLIST=$(jq -r --arg d "$DRIVER" '.[$d]' "$BACKEND_JSON")
[ -n "$VIPLIST" ] && [ "$VIPLIST" != "null" ] || fail "csi_backend.$DRIVER (VIP list) missing"
RELEASE="csi-$DRIVER"
IMG_REGISTRY="${IMAGE_REF%:*}"; IMG_TAG="${IMAGE_REF##*:}"
log "driver=$DRIVER  VIPs=$VIPLIST  image=$IMAGE_REF  chart=$CHART"

# ---- AKS subnet in the storage VNet + the VIP route table ------------------
# Pods (Azure CNI node-subnet) take IPs from this subnet; the route table makes
# the VIP /32s reachable (next hop = storage node NICs).
if ! az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$AKS_SUBNET" >/dev/null 2>&1; then
  log "creating AKS subnet $AKS_SUBNET ($AKS_SUBNET_CIDR) in $VNET"
  az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "$AKS_SUBNET" \
    --address-prefixes "$AKS_SUBNET_CIDR" >/dev/null
fi
if [ -n "$ROUTE_TABLE" ]; then
  log "associating route table $ROUTE_TABLE with $AKS_SUBNET (VIP reachability)"
  az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$AKS_SUBNET" \
    --route-table "$ROUTE_TABLE" >/dev/null
fi
SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$AKS_SUBNET" --query id -o tsv)

# ---- open the storage NSG so the AKS subnet can reach the NVMeoF ports -------
# NVMeoF is not world-exposed: the storage NSG admits only allowed_nvmeof_cidrs
# (default = storage subnet). Add an inbound allow for our AKS subnet (idempotent).
if [ "$OPEN_NSG" = "1" ]; then
  [ -n "$STORAGE_NSG" ] || STORAGE_NSG=$(derive_storage_nsg) || \
    fail "could not find the storage NVMeoF NSG; pass --storage-nsg <name> (or --no-open-nsg)"
  RULE="Allow-NVMeoF-$(echo "$AKS_SUBNET_CIDR" | tr './' '--')"
  log "opening NVMeoF ($NVMEOF_PORTS) from $AKS_SUBNET_CIDR on NSG $STORAGE_NSG"
  az network nsg rule create -g "$RG" --nsg-name "$STORAGE_NSG" -n "$RULE" \
    --priority 1011 --direction Inbound --access Allow --protocol Tcp \
    --source-address-prefixes "$AKS_SUBNET_CIDR" --destination-address-prefix '*' \
    --destination-port-ranges $NVMEOF_PORTS >/dev/null 2>&1 \
  || az network nsg rule update -g "$RG" --nsg-name "$STORAGE_NSG" -n "$RULE" \
    --source-address-prefixes "$AKS_SUBNET_CIDR" \
    --destination-port-ranges $NVMEOF_PORTS >/dev/null
fi

# ---- create the AKS cluster (Azure CNI, same VNet, ACR attached) ------------
if az aks show -g "$RG" -n "$CLUSTER" >/dev/null 2>&1; then
  log "AKS cluster $CLUSTER already exists"
else
  log "creating AKS cluster $CLUSTER ($NODES x $NODE_TYPE${SPOT:+ spot}, Azure CNI, vnet=$VNET)"
  az aks create -g "$RG" -n "$CLUSTER" --location "$LOCATION" \
    --network-plugin azure --vnet-subnet-id "$SUBNET_ID" \
    --service-cidr "$SERVICE_CIDR" --dns-service-ip "$DNS_SERVICE_IP" \
    --node-count "$NODES" --node-vm-size "$NODE_TYPE" \
    ${ZONE:+--zones "$ZONE"} \
    ${SPOT:+--priority Spot --eviction-policy Delete --spot-max-price -1} \
    ${ACR:+--attach-acr "$ACR"} \
    --generate-ssh-keys
fi
az aks get-credentials -g "$RG" -n "$CLUSTER" --overwrite-existing
[ -n "$ACR" ] && az aks update -g "$RG" -n "$CLUSTER" --attach-acr "$ACR" >/dev/null 2>&1 || true

# ---- load nvme_tcp on the nodes (block data path needs it) -----------------
# AKS Ubuntu nodes: modprobe + nvme-cli via nsenter into the host namespace.
log "ensuring nvme_tcp on all nodes"
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvme-tcp-loader
  namespace: kube-system
spec:
  selector: { matchLabels: { app: nvme-tcp-loader } }
  template:
    metadata: { labels: { app: nvme-tcp-loader } }
    spec:
      hostPID: true
      tolerations: [{ operator: Exists }]
      containers:
      - name: loader
        image: mcr.microsoft.com/mirror/docker/library/ubuntu:22.04
        securityContext: { privileged: true }
        command: ["/bin/sh","-c"]
        args:
          - |
            nsenter -t 1 -m -u -i -n -p -- sh -c \
              'modprobe nvme_tcp; command -v nvme >/dev/null || (apt-get update && apt-get install -y nvme-cli)'
            echo "nvme_tcp loaded; sleeping"; sleep infinity
EOF
kubectl -n kube-system rollout status ds/nvme-tcp-loader --timeout=180s

# ---- helm values (NATIVE: ordinary pod networking, ACR image) --------------
# No hostNetwork / no priorityClassName override -- the GKE-only workarounds.
VALUES=$(mktemp /tmp/aks-values-${DRIVER}.XXXXXX.yaml)
trap 'rm -f "$VALUES"' EXIT
if [ "$DRIVER" = "mayascale" ]; then
  cat > "$VALUES" <<EOF
fullnameOverride: ${RELEASE}
csiDriver: { name: csi-mayascale.zettalane.com, attachRequired: false }
controller:
  externalAttacher:    { enabled: false }
  externalSnapshotter: { enabled: true }
  externalResizer:     { enabled: true }
  externalProvisioner: { enabled: true }
  driver: { image: { registry: ${IMG_REGISTRY}, tag: ${IMG_TAG}, pullPolicy: IfNotPresent } }
node:
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
  externalAttacher:    { enabled: false }
  externalSnapshotter: { enabled: true }
  externalResizer:     { enabled: true }
  externalProvisioner: { enabled: true }
  driver: { image: { registry: ${IMG_REGISTRY}, tag: ${IMG_TAG}, pullPolicy: IfNotPresent } }
node:
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
# OCI charts need --version; an http(s)/.tgz URL pins the version in the path.
CV_ARG=""; case "$CHART" in oci://*) CV_ARG="--version $CHART_VERSION" ;; esac
helm upgrade --install "$RELEASE" "$CHART" $CV_ARG -n "$NS" --create-namespace -f "$VALUES"
kubectl -n "$NS" rollout status "deploy/${RELEASE}-controller" --timeout=240s

echo
log "driver '$RELEASE' is up on AKS cluster '$CLUSTER'. Pods (note real VNet IPs):"
kubectl -n "$NS" get pods -o wide
log "snapshot-controller is managed by AKS -- VolumeSnapshot path works out of the box."
log "Native check: kubectl apply a PVC on an nvme-of StorageClass + an fio pod."
log "Conformance (optional): csi-sanity-incluster.sh --backend-json $BACKEND_JSON --pool <name>"
log "Cleanup: $0 --cluster $CLUSTER --cleanup"
