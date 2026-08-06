# MayaScale CSI on AKS — Deployment & Architecture

Status: **validated end-to-end** against the `csitest3` MayaScale cluster
(2026-06-13). Driver image `1.0.11`, chart `1.0.0`. Deploy script: `aks-csi.sh`.
Both fio harnesses pass on all 4 pools (see §7).

This is the AKS-specific companion to `MANAGED_K8S_SUPPORT_PLAN.md` (the 3-cloud
plan). AKS is the easiest managed target: native pod-to-VIP routing **and** a
managed snapshot-controller.

---

## 1. The two-layer VM model (why `az vm list` shows nothing)

AKS splits into two layers; only one is your VMs:

| Layer | What | In your subscription? | Billed | Where to see it |
|---|---|---|---|---|
| **Control plane** | apiserver, etcd, scheduler, controller-manager, **snapshot-controller** | No — Azure-managed infra | No (SKU `Free`/Base) | n/a (managed) |
| **Worker nodes** | where pods run (2× `Standard_D4s_v3`) | **Yes** | **Yes** | NOT `az vm list` |

The workers are a **VM Scale Set** in an **auto-managed node resource group**, not
standalone VMs — that's why `az vm list` is empty:
- Node RG: `MC_<rg>_<cluster>_<location>` = `MC_mayanas-testing_zettalane-csi-aks_westus`
- VMSS: `aks-nodepool1-*-vmss` (capacity 2)
- See them: `az vmss list -g MC_mayanas-testing_zettalane-csi-aks_westus -o table`

**GKE contrast:** GKE also fully manages the control plane, but creates worker
nodes as individual Compute Engine VMs (a MIG) — visible in `gcloud compute
instances list` (the "3 VMs" you saw). AKS hides them in a VMSS under `MC_*`.
"Native" here means no GKE-style network workarounds — the nodes are still real VMs.

---

## 2. Architecture (what was tested)

```
  YOUR SUBSCRIPTION (Azure Sponsorship)        RG: mayanas-testing
  ┌──────────────────────────────────────────  VNet: mayascale-vnet 10.0.0.0/16 ┐
  │  AZURE-MANAGED (not your VMs)                                                │
  │  ┌───────────────────────────┐         ┌─────────────────────────────────┐  │
  │  │ AKS control plane (Free)  │         │ STORAGE: MayaScale csitest3      │  │
  │  │ apiserver/etcd/sched +    │         │ subnet mayascale-subnet 10.0.1/24│  │
  │  │ snapshot-controller       │         │  node1 10.0.1.4  node2 10.0.1.5  │  │
  │  └─────────────┬─────────────┘         │  active-active, configd RPC      │  │
  │                │ kubeconfig            │  nvmet portals auto-alloc 4430+  │  │
  │  RG: MC_..._zettalane-csi-aks          │  floating VIPs 10.0.100.7 / .8   │  │
  │  ┌─────────────┴─────────────┐         └──────────▲──────────────────────┘  │
  │  │ AKS workers = VMSS (2×    │     route-table: 10.0.100.7→10.0.1.4         │
  │  │ D4s_v3) aks-csi-subnet    │     ┌──────────────┤ nvme-tcp (VIP:4430+)    │
  │  │ 10.0.20.0/24              │     │  configd RPC  │ (data path)            │
  │  │  ┌──────────────────────┐ │     │  (provision/  │                        │
  │  │  │ csi controller pod   │─┼─────┘   snapshot)   │                        │
  │  │  │  real VNet IP .20.21  │ │                     │                        │
  │  │  ├──────────────────────┤ │     NSG: Allow-NVMeoF 10.0.20.0/24 → 4430+   │
  │  │  │ csi node DaemonSet   │─┼─────────────────────┘                        │
  │  │  │  + nvme-tcp-loader   │ │     Image: ACR zettalanecsi.azurecr.io       │
  │  │  ├──────────────────────┤ │                                              │
  │  │  │ app pod → PVC        │ │                                              │
  │  │  └──────────────────────┘ │                                              │
  │  └───────────────────────────┘                                              │
  └─────────────────────────────────────────────────────────────────────────────┘
```

Validated flow: app PVC → controller calls configd (provision) → configd
allocates an nvme-of portal at 4430+ on the VIP → node plugin `nvme connect`s to
`VIP:4430` → block device → mkfs+mount → app I/O.

---

## 3. Networking model (the parts that matter)

1. **Same VNet.** AKS sits in the storage VNet so Azure CNI pod IPs route to the
   VIPs. Dedicated subnet `aks-csi-subnet` 10.0.20.0/24 (chosen, not forced) — a
   separate subnet avoids IP-pressure on the storage subnet (Azure CNI burns ~30
   IPs/node).
2. **No hostNetwork.** VPC/VNet-native pod IPs reach the VIPs directly — the
   GKE-only `hostNetwork:true` + `priorityClassName:""` workarounds are dropped.
3. **Floating VIPs are UDR-based.** VIPs (10.0.100.7/.8) live OUTSIDE any subnet
   CIDR; reached via `mayanas-route-table` (`10.0.100.7/32 → 10.0.1.4`, type
   VirtualAppliance; node NICs have `enableIPForwarding=true`). The AKS node subnet
   must have that route table associated.
4. **K8s service CIDR must not overlap the VNet.** AKS default is 10.0.0.0/16,
   which collides with the storage VNet → override to `192.168.100.0/24`
   (dns `192.168.100.10`).
5. **NSG gate — the key step (§4).**

---

## 4. nvme-of ports & the NSG gate (NOT world-exposed by design)

The storage NSG (`nsg-<cluster>-*`, terraform `azure/mayascale/main.tf`) admits the
nvme-of ports only from **`var.allowed_nvmeof_cidrs`** (default = the storage
subnet). A separate client subnet (our AKS 10.0.20.0/24) is **dropped on the data
ports** until added.

**Which ports the client actually needs:** configd **auto-allocates the per-PVC
nvme-of portal from 4430 upward** (one per volume). The driver `nvme connect`s
straight to `VIP:<portalPort>` — there is **no 4420 discovery**, and **8009
discovery is backend-internal**. So open **only 4430+** for clients (we use
`4430-4500`).

Two ways to admit the AKS subnet:
- **Up front (preferred):** set `allowed_nvmeof_cidrs = ["10.0.1.0/24","10.0.20.0/24"]`
  at MayaScale deploy time → zero post-deploy NSG work.
- **After the fact:** add an inbound NSG allow for the AKS CIDR → `4430-4500`.
  `aks-csi.sh` automates this (`OPEN_NSG=1`, `--no-open-nsg` to skip,
  `--cleanup` removes it). It auto-derives the storage NSG (the one carrying the
  `NVMeoF-TCP` rule).

**Diagnostic tip:** if a pod can reach storage **node:22** but not the **VIP:port**,
it's the NSG port-gate, not routing. Probe from the ubuntu `nvme-tcp-loader` pod
(real bash) — the busybox `nc`/`/dev/tcp` in the driver container reports false
timeouts.

---

## 5. Snapshot-controller (AKS gives it free; EKS does not)

CSI snapshots need two pieces:
- **Per-driver sidecar** `csi-snapshotter` — ships in our controller pod; calls the
  driver `CreateSnapshot` RPC (→ configd → `zfs snapshot` / LVM snap).
- **Cluster singleton** `snapshot-controller` + the CRDs (`VolumeSnapshot`,
  `VolumeSnapshotContent`, `VolumeSnapshotClass`) — installed **once per cluster**,
  the brains that watch `VolumeSnapshot` objects and drive the sidecars.

| Cloud | snapshot-controller + CRDs |
|---|---|
| **AKS** | **Shipped, managed** (`storageProfile.snapshotController.enabled=true`; runs in the control plane, not a visible pod) |
| GKE | Shipped |
| EKS | **NOT shipped** — must `kubectl apply` external-snapshotter CRDs + controller |

This is what makes the MayaScale **ZFS-snapshot / dataset-branching** feature usable
via `kubectl create VolumeSnapshot` on AKS with no extra install.

> NOT yet exercised on AKS: only provision + attach + fio I/O are validated. A
> `VolumeSnapshot` + clone round-trip is the next test.

---

## 6. Customer runbook — AKS + MayaScale

The two stacks are independent; the work is the glue. Order of operations:

**At MayaScale deploy time (do up front to avoid rework):**
1. Deploy the **MayaScale storage cluster** into a VNet (marketplace/terraform).
   Capture **VNet + data VIPs + pools** = `csi_backend.json`
   (`terraform output -json csi_backend`).
2. Set **`allowed_nvmeof_cidrs`** to include the **AKS subnet CIDR** you'll use
   (§4). Single most important up-front item.

**AKS side (before deploying the driver):**
3. AKS cluster in the **same VNet** (or peered + routes), **Azure CNI**, a **real
   node pool** (not virtual-node), node subnet = the CIDR from step 2.
4. If VIPs are route-table-based, associate that **route table** with the AKS node
   subnet.
5. Ensure **`nvme_tcp`** loads on nodes (privileged DaemonSet `modprobe`).
6. Get the **driver image** into a registry AKS can pull: push to **ACR** +
   `az aks update --attach-acr`, or pull from the public registry.

**Deploy the CSI driver:**
7. `helm install` with the `csi_backend` (VIPs + pools) and image ref — **no
   hostNetwork / no priorityClass overrides** (AKS-native).
8. Create **StorageClass(es)** (`provisioner: csi-mayascale.zettalane.com`,
   `parameters: {protocol: nvme-of, pool: <pool>}`), then use PVCs.

Steps 3–7 are automated by `aks-csi.sh` (it also creates the subnet, associates the
route table, opens the NSG, loads nvme_tcp, attaches the ACR). One-liner shorthand:
> MayaScale + AKS just need to share a network, the AKS subnet must be in the
> storage's nvme-of allow-list (4430+), and nvme_tcp must be on the nodes.

---

## 7. This deployment — exact commands & results

Prereqs (one-time, billable): ACR with the image.
```
az acr create -g mayanas-testing -n zettalanecsi --sku Basic --location westus
# load + push the 1.0.11 image tar:
podman load -i zettalane-csi-1.0.11.tar
podman tag zettalane-csi:1.0.11 zettalanecsi.azurecr.io/zettalane-csi:1.0.11
TOKEN=$(az acr login -n zettalanecsi --expose-token --query accessToken -o tsv)
echo "$TOKEN" | podman login zettalanecsi.azurecr.io -u 00000000-0000-0000-0000-000000000000 --password-stdin
podman push zettalanecsi.azurecr.io/zettalane-csi:1.0.11
```

Cluster + driver + NSG + nvme_tcp (one shot):
```
./aks-csi.sh --backend-json csi_backend-csitest3.json --acr zettalanecsi
```

Validate (run the harnesses on the managed cluster with KUBECTL=kubectl):
```
KUBECTL=kubectl ./csi-fio-test.sh       --backend-json csi_backend-csitest3.json --runtime 20
KUBECTL=kubectl ./csi-fio-block-test.sh --backend-json csi_backend-csitest3.json --runtime 20
```

Results (all 4 pools, both nodes, vg + thinpool):
- **Filesystem fio**: PASS, err=0 — seqread 412–446 MB/s, seqwrite up to 366 MB/s,
  ~8–9k randread IOPS.
- **Raw-block fio**: PASS — 10–14k IOPS @ 4k qd16, ~1.1–1.5 ms latency.

Teardown (removes cluster + the NSG allow it added; leaves subnet):
```
./aks-csi.sh --cluster zettalane-csi-aks --cleanup
```

---

## 8. Environment-specific gotchas (decisions baked into `aks-csi.sh`)

| Gotcha | Resolution |
|---|---|
| Cluster is in the **Sponsorship** sub, not Pay-as-you-go | `SUBSCRIPTION=6aa9a5b8-...` default; `az account set` |
| `az vm list` empty | workers are a VMSS in `MC_*` RG (§1) |
| `Standard_D4s_v5` not allowed in this sub/westus | default `Standard_D4s_v3` |
| **westus has no availability zones** (`availability_zones=[]`) | omit `--zones` |
| AKS service CIDR 10.0.0.0/16 collides with VNet | override `192.168.100.0/24` |
| Chart vs image versions differ | chart `1.0.0` (published) ≠ image `1.0.11`; set separately |
| Helm chart 1.0.11 → 404 | publish line is 1.0.0; don't reuse image version for the chart |
| nvme-of blocked despite routing OK | open storage NSG for AKS CIDR on 4430+ (§4) |
| busybox probes lie | probe from the ubuntu nvme-tcp-loader pod |
| fio harness false-FAIL on slow image-pull | wait loop now polls terminal phase (fixed in `csi-fio-test.sh`) |
