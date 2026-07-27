#!/bin/bash
# install-cnpg.sh — install CloudNativePG + the cnpg-mayascale hot StorageClass.
# The operator runs every branch's Postgres Cluster; the SC binds their PVCs to
# MayaScale block (nvme-of) volumes. Prerequisite for install-zettabranch.sh.
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; K="k3s kubectl"
NS=cnpg-test; SC=cnpg-mayascale; POOL=${POOL:-data-pool-1}
log(){ echo "[install-cnpg] $*"; }

log "1. install CloudNativePG operator (helm)"
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null 2>&1 || helm repo update >/dev/null 2>&1
helm upgrade --install cnpg cnpg/cloudnative-pg -n cnpg-system --create-namespace --wait --timeout 6m 2>&1 | tail -2
$K -n cnpg-system get deploy 2>/dev/null

log "2. hot StorageClass ${SC} (MayaScale block, pool ${POOL})"
$K create ns $NS >/dev/null 2>&1 || true
$K apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: ${SC} }
provisioner: csi-mayascale.zettalane.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters: { protocol: nvme-of, pool: ${POOL}, fsType: xfs }
EOF
log "done — CNPG operator + ${SC} ready"
