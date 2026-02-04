# MayaScale Terraform Module for Google Cloud

Deploy MayaScale high-performance NVMe-oF block storage on Google Cloud Platform.

## Overview

MayaScale provides ultra-high-performance distributed block storage with:
- NVMe-over-Fabrics (NVMe-oF/TCP) protocol
- Sub-millisecond latency
- Up to 1.4M IOPS per node pair
- ZFS reliability and data integrity
- Cross-zone synchronous replication for HA

## Prerequisites

1. **GCP Project** with billing enabled
2. **APIs enabled:**
   ```bash
   gcloud services enable compute.googleapis.com
   gcloud services enable iam.googleapis.com
   ```
3. **Terraform** >= 0.14
4. **gcloud CLI** authenticated

## Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/zettalane-systems/zettalane-terraform.git
   cd terraform/gcp/mayascale
   ```

2. Create your configuration:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your settings:
   ```hcl
   project_id = "your-gcp-project-id"
   region     = "us-central1"
   cluster_name = "my-mayascale"
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

| Policy | Machine Type | Local SSDs | Write IOPS | Read IOPS |
|--------|-------------|------------|------------|-----------|
| zonal-standard-performance | n2-highcpu-8 | 2 | 130K | 380K |
| zonal-medium-performance | n2-highcpu-16 | 4 | 200K | 700K |
| zonal-high-performance | n2-highcpu-32 | 8 | 350K | 900K |
| zonal-ultra-performance | n2-highcpu-64 | 16 | 700K | 1.4M |
| regional-* | (same) | (same) | 90% of zonal | Same as zonal |

**Zonal** policies deploy both nodes in the same zone for optimal latency.
**Regional** policies deploy nodes across zones for higher durability.

## Configuration

### Required Variables

| Variable | Description |
|----------|-------------|
| project_id | GCP project ID |
| cluster_name | Deployment name (used for resource naming) |

### Common Variables

| Variable | Default | Description |
|----------|---------|-------------|
| region | us-central1 | GCP region |
| zone | us-central1-a | GCP zone |
| performance_policy | regional-high-performance | Performance tier |
| machine_type | (auto) | Override machine type |
| use_spot_vms | false | Use Spot VMs for cost savings |

### Advanced Variables

| Variable | Default | Description |
|----------|---------|-------------|
| client_protocol | nvme | Client protocol: nvme, iscsi, both |
| client_nvme_port | 4420 | NVMe-oF port |
| deployment_type | active-active | Deployment architecture |
| shares | [] | NFS/SMB shares (optional) |

## Outputs

| Output | Description |
|--------|-------------|
| node1_public_ip | External IP of node 1 |
| node1_private_ip | Internal IP of node 1 |
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
- **Compute**: Machine type and hours
- **Local SSDs**: Included with instance pricing
- **Network**: Egress traffic
- **Software**: MayaScale license (metered via GCP Marketplace)

Use Spot VMs (`use_spot_vms = true`) for 60-90% compute savings in dev/test.

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
