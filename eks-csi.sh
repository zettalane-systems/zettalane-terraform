#!/usr/bin/env bash
#
# eks-csi.sh — create an EKS cluster and deploy the ZettaLane CSI driver,
# pulling the image + Helm chart from PUBLIC ghcr (self-contained, no registry
# setup). Mirrors aks-csi.sh's ghcr defaults; --ecr opts into ECR for air-gap.
#
# Why EKS is the NATIVE path (vs the GKE script's workarounds):
#   * VPC CNI gives every pod a real, routable VPC IP. The controller talks to
#     the storage data VIPs DIRECTLY -- no `hostNetwork: true`, no node-netns
#     borrow, no ip-masq/SNAT carve-out. (GKE needed hostNetwork because it does
#     not SNAT pod->node egress for RFC1918 VIPs.) So we deploy the controller as
#     an ordinary pod.
#   * No gke-resource-quotas: the system-*-critical priorityClass works in any
#     namespace, so we drop the `priorityClassName: ""` override too.
#
# Two things EKS lacks that AKS/GKE give for free, handled here:
#   * VolumeSnapshot CRDs + snapshot-controller: EKS does NOT ship them, so the
#     csi-snapshotter sidecar would crashloop. We install external-snapshotter
#     (CRDs + controller) before deploy (--no-snapshotter to skip).
#   * Image pull auth: with the public ghcr default there is NO pull secret and
#     no ECR. --ecr <registry> opts into ECR (managed-node IAM role gets
#     ECRReadOnly via eksctl) for an air-gapped/private image.
#
# The EKS nodes must sit in the SAME VPC as the storage cluster so pods reach the
# data VIPs with no peering. We pin the node group to the storage AZ (--az) so the
# nvme-of data path stays in-AZ; the EKS control plane still spans >=2 subnets.
# nvme_tcp is loaded on the nodes by a small privileged DaemonSet (AL2023 ships
# the module; the block path needs `modprobe nvme_tcp` + nvme-cli for `nvme
# connect`).
#
# Storage SG note (AWS analog of Azure's NSG allowed_nvmeof_cidrs): the
# aws/mayascale SG already admits ALL traffic from the whole VPC CIDR, so an EKS
# cluster IN THE SAME VPC is allowed on the nvme-of portals with NO SG change.
# --open-sg is only for a peered/cross-VPC EKS: it adds an inbound allow for the
# node subnet CIDRs on the per-PVC portal ports (4430+) to the storage SG.
#
# Usage: eks-csi.sh --backend-json <file> [options]
#   --backend-json <file>  csi_backend.json (driver + VIP list + pools)   [required]
#   --image <ref>          CSI image (default: PUBLIC ghcr.io/zettalane-systems/zettalane-csi:<ver>)
#   --chart <ref>          chart .tgz | oci:// | http(s) URL
#                          (default: oci://ghcr.io/zettalane-systems/charts/zettalane-csi)
#   --cluster <name>       EKS cluster name (default: zettalane-csi-eks)
#   --ecr <registry>       OPTIONAL: pull the image from ECR instead of public ghcr
#                          (<acct>.dkr.ecr.<region>.amazonaws.com; image must be pushed there)
#   --nodes  N             managed node group size (default: 2)
#   --node-type <type>     EC2 instance type (default: m5.large)
#   --az <zone>            AZ to pin the node group to (colocate with storage;
#                          default: first AZ of the storage VPC's subnets)
#   --open-sg              add a storage-SG ingress for the node subnets on 4430+
#                          (only needed for a peered/cross-VPC EKS; --storage-sg to name it)
#   --storage-sg <id>      storage SG id for --open-sg (default: auto-derive the
#                          one carrying the NVMe-oF client rule)
#   --spot                 spot nodes (cheaper; fine for the CSI test side)
#   --cleanup              helm uninstall + `eksctl delete cluster`, then exit
# Env: REGION (us-east-1), VPC_ID (default-VPC of the region if unset),
#      IMAGE_VERSION (1.0.1), CHART_VERSION (1.0.0), NVMEOF_PORTS (4430-4500),
#      SNAPSHOTTER_VERSION (v8.2.0)

set -euo pipefail
log()  { echo "[eks-csi] $*"; }
fail() { echo "[eks-csi] ERROR: $*" >&2; exit 1; }

BACKEND_JSON=""; CLEANUP=0
CLUSTER="${CLUSTER:-zettalane-csi-eks}"
ECR="${ECR:-}"
NODES="${NODES:-2}"
NODE_TYPE="${NODE_TYPE:-m5.large}"
REGION="${REGION:-us-east-1}"
VPC_ID="${VPC_ID:-}"
AZ=""
SPOT=""
# Chart and image are versioned INDEPENDENTLY: the chart tracks its own line
# (published 1.0.0), the image tracks the driver build (1.0.1).
CHART_VERSION="${CHART_VERSION:-1.0.0}"
IMAGE_VERSION="${IMAGE_VERSION:-1.0.1}"
# external-snapshotter (CRDs + controller) — EKS doesn't ship it.
SNAPSHOTTER_VERSION="${SNAPSHOTTER_VERSION:-v8.2.0}"
INSTALL_SNAPSHOTTER="${INSTALL_SNAPSHOTTER:-1}"
# AZs the EKS control plane cannot live in (us-east-1e has no EKS support); their
# subnets are dropped from the control-plane list. Node group still uses --az.
EXCLUDE_AZS="${EXCLUDE_AZS:-us-east-1e}"
# The storage SG admits the whole VPC CIDR already, so same-VPC EKS needs nothing.
# --open-sg (peered/cross-VPC) adds an allow for the node subnets on these ports:
# the per-PVC portals configd auto-allocates from 4430 up (no 4420 discovery).
NVMEOF_PORTS="${NVMEOF_PORTS:-4430-4500}"
OPEN_SG="${OPEN_SG:-0}"
STORAGE_SG="${STORAGE_SG:-}"
NS="zettalane-csi"

while [ $# -gt 0 ]; do
  case "$1" in
    --backend-json) BACKEND_JSON="$2"; shift 2 ;;
    --image)        IMAGE_REF="$2";    shift 2 ;;
    --chart)        CHART="$2";        shift 2 ;;
    --cluster)      CLUSTER="$2";      shift 2 ;;
    --ecr)          ECR="$2";          shift 2 ;;
    --nodes)        NODES="$2";        shift 2 ;;
    --node-type)    NODE_TYPE="$2";    shift 2 ;;
    --az)           AZ="$2";           shift 2 ;;
    --open-sg)      OPEN_SG=1;         shift ;;
    --storage-sg)   STORAGE_SG="$2";   shift 2 ;;
    --no-snapshotter) INSTALL_SNAPSHOTTER=0; shift ;;
    --spot)         SPOT=1;            shift ;;
    --cleanup)      CLEANUP=1;         shift ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown arg: $1 (try --help)" ;;
  esac
done

for t in aws eksctl kubectl helm jq; do command -v "$t" >/dev/null || fail "'$t' not on PATH"; done

# Default to PUBLIC ghcr (self-contained, no registry setup). --ecr overrides to an
# ECR ref; --image overrides explicitly. --chart defaults to the ghcr OCI chart.
IMAGE_REF="${IMAGE_REF:-${ECR:+${ECR}/zettalane-csi:${IMAGE_VERSION}}}"
IMAGE_REF="${IMAGE_REF:-ghcr.io/zettalane-systems/zettalane-csi:${IMAGE_VERSION}}"
CHART="${CHART:-oci://ghcr.io/zettalane-systems/charts/zettalane-csi}"

# Find the storage SG = the one carrying the NVMe-oF client ingress rule.
derive_storage_sg() {
  aws ec2 describe-security-groups --region "$REGION" \
    --filters Name=vpc-id,Values="$VPC_ID" \
    --query "SecurityGroups[?IpPermissions[?ToPort==\`$((4420+16))\` || FromPort==\`4420\`]].GroupId | [0]" \
    --output text 2>/dev/null
}

# ---- cleanup ---------------------------------------------------------------
if [ "$CLEANUP" -eq 1 ]; then
  if aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" 2>/dev/null; then
    helm -n "$NS" uninstall "csi-mayascale" 2>/dev/null || true
    helm -n "$NS" uninstall "csi-mayanas"   2>/dev/null || true
  fi
  log "deleting EKS cluster $CLUSTER (region $REGION)"
  eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait
  log "leaving any --open-sg ingress rule in place (revoke by hand if added)"
  exit 0
fi

[ -n "$BACKEND_JSON" ] && [ -f "$BACKEND_JSON" ] || fail "--backend-json <file> is required"
[ -n "$IMAGE_REF" ] || fail "no image: pass --ecr <registry> (image pushed there) or --image <ref>"
DRIVER=$(jq -r '.driver' "$BACKEND_JSON")
case "$DRIVER" in mayascale|mayanas|mayanas-lustre) : ;; *) fail "bad driver in backend: $DRIVER" ;; esac
VIPLIST=$(jq -r --arg d "$DRIVER" '.[$d]' "$BACKEND_JSON")
[ -n "$VIPLIST" ] && [ "$VIPLIST" != "null" ] || fail "csi_backend.$DRIVER (VIP list) missing"
RELEASE="csi-$DRIVER"
IMG_REGISTRY="${IMAGE_REF%:*}"; IMG_TAG="${IMAGE_REF##*:}"
log "driver=$DRIVER  VIPs=$VIPLIST  image=$IMAGE_REF  chart=$CHART"

# ---- resolve the storage VPC + subnets -------------------------------------
# Same VPC as the storage nodes so VPC-CNI pod IPs route to the data VIPs.
if [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
  [ "$VPC_ID" != "None" ] || fail "no default VPC in $REGION; set VPC_ID to the storage VPC"
fi
# Public subnets across this VPC (control plane wants >=2 AZs). AZ -> subnet map.
mapfile -t ALL_SUBNET_AZS < <(aws ec2 describe-subnets --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text)
# Drop subnets in EKS-unsupported AZs (control plane can't span them).
SUBNET_AZS=()
for row in "${ALL_SUBNET_AZS[@]}"; do
  read -r _ saz <<<"$row"
  case " $EXCLUDE_AZS " in *" $saz "*) continue ;; esac
  SUBNET_AZS+=("$row")
done
[ "${#SUBNET_AZS[@]}" -ge 2 ] || fail "need >=2 EKS-capable public subnets in $VPC_ID (found ${#SUBNET_AZS[@]}; excluded: $EXCLUDE_AZS)"
# `aws --output text` columns are TAB-separated -> split with read (not ${..%% *}).
[ -z "$AZ" ] && read -r _ AZ <<<"${SUBNET_AZS[0]}"
log "VPC=$VPC_ID  node-group AZ=$AZ (control plane spans ${#SUBNET_AZS[@]} subnets)"

# ---- (optional) open the storage SG for a peered/cross-VPC EKS --------------
# Same-VPC EKS is already admitted by the SG's all-VPC-CIDR rule -> no-op default.
if [ "$OPEN_SG" = "1" ]; then
  [ -n "$STORAGE_SG" ] || STORAGE_SG=$(derive_storage_sg) || true
  [ -n "$STORAGE_SG" ] && [ "$STORAGE_SG" != "None" ] || \
    fail "could not find the storage SG; pass --storage-sg <id>"
  for row in "${SUBNET_AZS[@]}"; do
    read -r sid _ <<<"$row"
    cidr=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$sid" \
      --query 'Subnets[0].CidrBlock' --output text)
    log "opening NVMe-oF ($NVMEOF_PORTS) from $cidr on SG $STORAGE_SG"
    pr="${NVMEOF_PORTS%-*}"; pr2="${NVMEOF_PORTS#*-}"
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$STORAGE_SG" \
      --protocol tcp --port "${pr}-${pr2}" --cidr "$cidr" >/dev/null 2>&1 \
      || log "  (rule already present for $cidr)"
  done
fi

# ---- create the EKS cluster (AL2023 managed nodes, same VPC, node group pinned
#      to the storage AZ) -----------------------------------------------------
if eksctl get cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  log "EKS cluster $CLUSTER already exists"
else
  SUBNET_LINES=""
  for row in "${SUBNET_AZS[@]}"; do
    read -r sid saz <<<"$row"
    SUBNET_LINES+="      ${saz}: { id: ${sid} }"$'\n'
  done
  log "creating EKS cluster $CLUSTER ($NODES x $NODE_TYPE${SPOT:+ spot}, AL2023, vpc=$VPC_ID)"
  eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER}
  region: ${REGION}
iam:
  withOIDC: true              # IRSA-ready (not needed for the nvme-of data path)
vpc:
  id: ${VPC_ID}
  subnets:
    public:
${SUBNET_LINES}
managedNodeGroups:
  - name: ng-csi
    instanceType: ${NODE_TYPE}
    desiredCapacity: ${NODES}
    availabilityZones: [${AZ}]   # colocate with storage -> in-AZ data path
    amiFamily: AmazonLinux2023
    spot: ${SPOT:+true}${SPOT:-false}
    iam:
      withAddonPolicies:
        ebs: false
EOF
fi
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"

# ---- install external-snapshotter (CRDs + controller) ----------------------
# EKS does NOT ship the VolumeSnapshot CRDs or the snapshot-controller (AKS/GKE
# do). Without them the csi-snapshotter sidecar crashloops. Idempotent apply.
if [ "$INSTALL_SNAPSHOTTER" = "1" ]; then
  log "installing external-snapshotter $SNAPSHOTTER_VERSION (CRDs + controller)"
  base="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}"
  for f in \
    client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
    client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
    client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml \
    deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml \
    deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml ; do
    kubectl apply -f "${base}/${f}"
  done
  kubectl -n kube-system rollout status deploy/snapshot-controller --timeout=120s
fi

# ---- load nvme_tcp + install nvme-cli on the nodes -------------------------
# AL2023 ships the nvme_tcp module (not autoloaded) but NOT nvme-cli. A tiny
# privileged DaemonSet, host-side via `chroot /proc/1/root` (the amazonlinux2023
# image has no nsenter), modprobes nvme_tcp and installs nvme-cli. nvme-cli
# provides /etc/nvme (the node plugin hostPath-mounts it, type: Directory, must
# pre-exist) but NOT hostnqn/hostid, so we generate a stable per-node identity.
log "ensuring nvme_tcp + nvme-cli on all nodes"
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
        image: public.ecr.aws/amazonlinux/amazonlinux:2023
        securityContext: { privileged: true }
        command: ["/bin/sh","-c"]
        args:
          - |
            chroot /proc/1/root sh -c '
              modprobe nvme_tcp
              rpm -q nvme-cli >/dev/null 2>&1 || dnf install -y nvme-cli
              [ -s /etc/nvme/hostnqn ] || nvme gen-hostnqn > /etc/nvme/hostnqn
              [ -s /etc/nvme/hostid ]  || cat /proc/sys/kernel/random/uuid > /etc/nvme/hostid'
            echo "nvme_tcp + nvme-cli ready; sleeping"; sleep infinity
EOF
kubectl -n kube-system rollout status ds/nvme-tcp-loader --timeout=180s

# ---- helm values (NATIVE: ordinary pod networking, ghcr/ECR image) ---------
# No hostNetwork / no priorityClassName override -- the GKE-only workarounds.
VALUES=$(mktemp /tmp/eks-values-${DRIVER}.XXXXXX.yaml)
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
log "driver '$RELEASE' is up on EKS cluster '$CLUSTER'. Pods (note real VPC IPs):"
kubectl -n "$NS" get pods -o wide
log "image from $IMAGE_REF; chart from $CHART. Native check: kubectl apply a PVC on"
log "an nvme-of StorageClass + an fio pod -- no in-cluster sanity harness needed."
log "Conformance (optional): csi-sanity-incluster.sh --backend-json $BACKEND_JSON --pool <name>"
log "Cleanup: $0 --backend-json $BACKEND_JSON --cleanup   (deletes the cluster)"
