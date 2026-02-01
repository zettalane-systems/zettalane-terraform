# MayaScale Terraform Module for Azure

Deploy MayaScale high-performance NVMe-oF block storage on Microsoft Azure.

## Overview

MayaScale provides ultra-high-performance distributed block storage with:
- NVMe-over-Fabrics (NVMe-oF/TCP) protocol
- Sub-millisecond latency
- Up to 2.88M read IOPS / 1.15M write IOPS per node pair
- ZFS reliability and data integrity
- Cross-zone synchronous replication for HA

## Prerequisites

1. **Azure Subscription** with appropriate permissions
2. **Azure CLI** authenticated:
   ```bash
   az login
   ```
3. **Terraform** >= 0.14
4. **Accept marketplace terms** (first time only):
   ```bash
   az vm image terms accept --publisher zettalane_systems-5254599 \
     --offer mayascale-cloud-ent --plan mayascale-cloud-ent
   ```

## Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/zettalane-systems/terraform.git
   cd terraform/azure/mayascale
   ```

2. Create your configuration:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your settings:
   ```hcl
   subscription_id = "your-subscription-id"
   cluster_name    = "my-mayascale"
   location        = "westus"
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
   terraform output ssh_command_node1

   # Get connection info
   terraform output deployment_summary
   ```

## Performance Policies

Azure uses L-series VMs with local NVMe storage (Laosv4 recommended):

| Policy | VM Size | NVMe Disks | Write IOPS | Read IOPS |
|--------|---------|------------|------------|-----------|
| zonal-basic-performance | L2as_v4 | 1 | 55K | 137K |
| zonal-standard-performance | L4aos_v4 | 3 | 144K | 360K |
| zonal-medium-performance | L8aos_v4 | 6 | 288K | 720K |
| zonal-high-performance | L24aos_v4 | 9 | 864K | 2.16M |
| zonal-ultra-performance | L32aos_v4 | 12 | 1.15M | 2.88M |
| regional-* | (same) | (same) | 83% of zonal | Same as zonal |

**Zonal** policies deploy both nodes in the same zone for optimal latency (~1ms).
**Regional** policies deploy nodes across zones for higher durability (~1.5ms).

## Configuration

### Required Variables

| Variable | Description |
|----------|-------------|
| subscription_id | Azure subscription ID |
| cluster_name | Cluster name (max 15 chars, lowercase) |

### Common Variables

| Variable | Default | Description |
|----------|---------|-------------|
| location | westus | Azure region |
| performance_policy | regional-standard-performance | Performance tier |
| instance_family | laosv4 | L-series family (laosv4, lasv4, lsv3, lsv2) |
| use_spot_vms | false | Use Spot VMs for cost savings |

### Network Variables

| Variable | Default | Description |
|----------|---------|-------------|
| resource_group_name | (auto) | Resource group (created if not specified) |
| vnet_name | (auto) | Virtual network name |
| ssh_source_ranges | ["0.0.0.0/0"] | CIDR ranges for SSH access |

## Outputs

| Output | Description |
|--------|-------------|
| node1_public_ip | Public IP of node 1 |
| node1_private_ip | Private IP of node 1 |
| vip1_address | Virtual IP 1 for client access |
| vip2_address | Virtual IP 2 for client access |
| ssh_command_node1 | SSH command to connect |
| deployment_summary | Human-readable summary |

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

## Cost Estimation

Costs depend on:
- **Compute**: VM size and hours
- **Storage**: Included with L-series VMs (ephemeral NVMe)
- **Network**: Egress traffic
- **Software**: MayaScale license (metered via Azure Marketplace)

Use Spot VMs (`use_spot_vms = true`) for significant cost savings in dev/test.

## Cleanup

```bash
terraform destroy
```

## Support

- Documentation: https://docs.zettalane.com
- Issues: https://github.com/zettalane-systems/terraform/issues
- Email: support@zettalane.com

## License

Apache 2.0 - See [LICENSE](../../LICENSE)
