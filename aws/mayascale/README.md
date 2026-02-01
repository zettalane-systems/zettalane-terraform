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
   git clone https://github.com/zettalane-systems/terraform.git
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
   terraform output ssh_command_node1

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

- Documentation: https://docs.zettalane.com
- Issues: https://github.com/zettalane-systems/terraform/issues
- Email: support@zettalane.com

## License

Apache 2.0 - See [LICENSE](../../LICENSE)
