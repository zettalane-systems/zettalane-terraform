#!/bin/bash
# install-snapshotter.sh — enable the CSI VolumeSnapshot path on a k3s client.
# k3s does NOT ship the VolumeSnapshot CRDs / snapshot-controller (AKS+GKE do; EKS+k3s don't),
# and our chart ships with controller.externalSnapshotter.enabled=false on purpose (the
# csi-snapshotter sidecar crashloops without the CRDs). So: CRDs + controller FIRST, then
# flip the sidecar on, then a VolumeSnapshotClass.  See CSI_SNAPSHOTTER_NOTES.md.
# Version + URL set mirror eks-csi.sh (the E2E-validated block).
#
# Usage: sudo ./install-snapshotter.sh [--version v8.2.0] [--release csi-mayascale] [--verify-only]
set -uo pipefail
log(){ echo "[snapshotter] $*"; }
V="${SNAPSHOTTER_VERSION:-v8.2.0}"; REL=csi-mayascale; NS=zettalane-csi; VERIFY=0
CHART="oci://ghcr.io/zettalane-systems/charts/zettalane-csi"; CHART_VER=1.0.0
while [ $# -gt 0 ]; do case "$1" in
  --version) V="$2"; shift 2;; --release) REL="$2"; shift 2;; --verify-only) VERIFY=1; shift;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;; *) echo "unknown: $1">&2; exit 2;; esac; done
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; K="k3s kubectl"

verify(){
  echo "--- CRDs ---";        $K get crd 2>/dev/null | grep -i snapshot || echo "  NONE"
  echo "--- snapshot-controller ---"; $K get deploy -n kube-system 2>/dev/null | grep -i snapshot || echo "  NONE"
  echo "--- csi-snapshotter sidecar in the controller pod ---"
  P=$($K get pods -n $NS -o name 2>/dev/null | grep controller | head -1)
  [ -n "$P" ] && $K get "$P" -n $NS -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null | sed 's/^/  /'
  echo "--- VolumeSnapshotClass ---"; $K get volumesnapshotclass 2>/dev/null || echo "  NONE"
}
[ "$VERIFY" -eq 1 ] && { verify; exit 0; }

# ---- 1. CRDs + snapshot-controller (mirrors eks-csi.sh lines ~227-241) -------
log "installing external-snapshotter $V (CRDs + snapshot-controller)"
base="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${V}"
for f in \
  client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
  client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
  client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml \
  deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml \
  deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml ; do
  $K apply -f "${base}/${f}" 2>&1 | sed 's/^/  /'
done
$K -n kube-system rollout status deploy/snapshot-controller --timeout=120s 2>&1 | tail -1

# ---- 2. THEN enable our csi-snapshotter sidecar (needs the CRDs to exist) ----
log "enabling controller.externalSnapshotter on release '$REL'"
helm upgrade "$REL" "$CHART" --version "$CHART_VER" -n "$NS" --reuse-values \
  --set controller.externalSnapshotter.enabled=true --wait --timeout 5m 2>&1 | grep -E 'STATUS|REVISION|Error' | sed 's/^/  /'
$K -n "$NS" rollout status deploy/${REL}-controller --timeout=180s 2>&1 | tail -1

# ---- 3. VolumeSnapshotClass -------------------------------------------------
log "creating VolumeSnapshotClass 'csi-mayascale-vsc'"
$K apply -f - <<EOF 2>&1 | sed 's/^/  /'
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata: { name: csi-mayascale-vsc }
driver: csi-mayascale.zettalane.com
deletionPolicy: Delete
EOF

echo; log "verify:"; verify
