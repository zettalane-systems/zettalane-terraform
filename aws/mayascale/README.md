# MayaScale Terraform Module for AWS

Deploy MayaScale high-performance NVMe-oF block storage on Amazon Web Services.

## Overview

MayaScale provides ultra-high-performance distributed block storage with:
- NVMe-over-Fabrics (NVMe-oF/TCP) protocol
- Sub-millisecond latency
- Up to 1.35M IOPS per node pair
- ZFS reliability and data integrity
- Cross-AZ synchronous replication for HA

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **EC2 Key Pair** in the target region
3. **AWS Marketplace Subscription** to MayaScale:
   - Visit [AWS Marketplace](https://aws.amazon.com/marketplace)
   - Search for "MayaScale" and subscribe
4. **Terraform** >= 0.14
5. **AWS CLI** configured with credentials

## Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/zettalane-systems/zettalane-terraform.git
   cd terraform/aws/mayascale
   ```

2. Create your configuration:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your settings:
   ```hcl
   key_pair_name = "your-key-pair"
   cluster_name  = "my-mayascale"
   ```

4. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

5. Access your deployment:
   ```bash
   # SSH to node
   terraform output ssh_commands

   # Get connection info
   terraform output deployment_summary
   ```

## Performance Policies

| Policy | Instance Type | NVMe Storage | Write IOPS | Read IOPS |
|--------|--------------|--------------|------------|-----------|
| zonal-basic-performance | i4i.xlarge | 937 GB | 57K | 204K |
| zonal-standard-performance | i3en.2xlarge | 5 TB | 135K | 346K |
| zonal-medium-performance | i3en.xlarge | 2.5 TB | 175K | 650K |
| zonal-high-performance | i3en.6xlarge | 15 TB | 368K | 992K |
| zonal-ultra-performance | i3en.12xlarge | 30 TB | 528K | 1.35M |
| regional-* | (same) | (same) | 90% of zonal | Same as zonal |

**Zonal** policies deploy both nodes in the same AZ for optimal latency.
**Regional** policies deploy nodes across AZs for higher durability.

## Configuration

### Required Variables

| Variable | Description |
|----------|-------------|
| key_pair_name | EC2 Key Pair name for SSH access |

### Common Variables

| Variable | Default | Description |
|----------|---------|-------------|
| region | us-east-1 | AWS region |
| cluster_name | (auto) | Cluster name for resources |
| performance_policy | zonal-medium-performance | Performance tier |
| use_spot_instances | true | Use Spot instances for savings |

### Network Variables

| Variable | Default | Description |
|----------|---------|-------------|
| vpc_id | (default VPC) | VPC for deployment |
| availability_zone | (auto) | Primary availability zone |
| ssh_cidr_blocks | ["10.0.0.0/8"] | CIDR ranges for SSH access |

## Outputs

| Output | Description |
|--------|-------------|
| node1_public_ip | Public IP of node 1 |
| node1_private_ip | Private IP of node 1 |
| vip1_address | Virtual IP 1 for client access |
| vip2_address | Virtual IP 2 for client access |
| ssh_commands | SSH commands for both nodes |

### Private-only deployments (no public IPs)

`assign_public_ip` defaults to `false`, which is the right posture for production. Set
it to `true` for direct SSH access to the nodes, as the Quick Start above does.

Leaving it `false` requires outbound connectivity that this module does **not** create,
and what that takes differs by cloud. **Please consult a ZettaLane Systems support
engineer before deploying without public IPs** — support@zettalane.com.

| assign_public_ip | **false** | Assign public IPs to the nodes; see [Private-only deployments](#private-only-deployments-no-public-ips) |
| deployment_summary | Human-readable summary |
| csi_backend | Driver config + pool map for the ZettaLane CSI driver (set `deployment_type = vg-active-active`) |

## Client Connection

After deployment, connect NVMe-oF volumes from clients:

```bash
# Get VIP addresses
VIP1=$(terraform output -raw vip1_address)
VIP2=$(terraform output -raw vip2_address)

# Discover NVMe subsystems
sudo nvme discover -t tcp -a $VIP1 -s 4420

# Connect to volumes
sudo nvme connect-all -t tcp -a $VIP1 -s 4420

# List connected NVMe devices
sudo nvme list
```

## Kubernetes (CSI driver)

To provision MayaScale block volumes from Kubernetes (EKS) via the ZettaLane CSI
driver (`provisioner: csi-mayascale.zettalane.com`), deploy with
`deployment_type = "vg-active-active"`. The cluster then builds a per-node CSI
volume group + thin pool instead of the default `data-node-X` block auto-export,
and the driver carves a per-PVC LV + per-volume NVMe-oF subsystem on demand.

```hcl
deployment_type = "vg-active-active"
```

Wire the `csi_backend` output straight into the driver's Helm values / config Secret:

```bash
terraform output -json csi_backend \
  | jq '{driver:.driver, mayascale:.mayascale, pools:.pools}' > values-backend.yaml
helm upgrade --install csi-mayascale ./charts/zettalane-csi -f values-backend.yaml
```

A block StorageClass then references a discovered pool:

```yaml
provisioner: csi-mayascale.zettalane.com
parameters:
  protocol: nvme-of
  pool: <cluster>-vg-node1      # from csi_backend.pools
```

**Networking:** run EKS in the **same VPC** (or a peered VPC) as the cluster. The
module's security group already admits all in-VPC traffic, so the CSI controller
reaches rpcbind + configd (control) and worker nodes reach the per-PVC NVMe-oF
portal (data) with no extra rule. For a cross-VPC/peered cluster, add the EKS
node security group to the MayaScale SG ingress.

## Cost Estimation

Costs depend on:
- **Compute**: Instance type and hours
- **Storage**: Included with instance pricing (NVMe SSDs)
- **Network**: Data transfer
- **Software**: MayaScale license (metered via AWS Marketplace)

Use Spot instances (`use_spot_instances = true`) for 50-70% compute savings.

## Cleanup

```bash
terraform destroy
```

## Support

- Documentation: https://zettalane.com
- Issues: https://github.com/zettalane-systems/zettalane-terraform/issues
- Email: support@zettalane.com

## License

Apache 2.0 - See [LICENSE](../../LICENSE)
