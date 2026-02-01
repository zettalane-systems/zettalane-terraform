# MayaNAS Terraform Module for AWS

Deploy MayaNAS enterprise NFS storage on Amazon Web Services.

## Overview

MayaNAS provides high-performance NFS storage with:
- ZFS reliability and data integrity
- Automatic tiering to Amazon S3
- Active-Active HA for high availability
- NFSv3/NFSv4 and SMB protocol support

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **AWS CLI** authenticated:
   ```bash
   aws configure
   ```
3. **Subscribe to MayaNAS** on AWS Marketplace (required for AMI access):
   - Visit [MayaNAS on AWS Marketplace](https://aws.amazon.com/marketplace)
   - Search for "MayaNAS" or "ZettaLane"
   - Subscribe to the product
4. **EC2 Key Pair** created in your target region
5. **Terraform** >= 0.14

## Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/zettalane-systems/terraform.git
   cd terraform/aws/mayanas
   ```

2. Create your configuration:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your settings:
   ```hcl
   key_pair_name = "your-key-pair"
   # ami_id is auto-detected from marketplace subscription
   ```

4. Deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

5. Access your deployment:
   ```bash
   # Get connection info
   terraform output deployment_summary

   # SSH to node
   ssh -i ~/.ssh/your-key.pem ec2-user@$(terraform output -raw node1_public_ip)
   ```

## Deployment Types

| Type | Nodes | Use Case |
|------|-------|----------|
| single | 1 | Development, testing |
| active-passive | 2 | HA with failover (default) |
| active-active | 2 | HA with load balancing |

## Configuration

### Required Variables

| Variable | Description |
|----------|-------------|
| key_pair_name | EC2 Key Pair name for SSH access |

### Common Variables

| Variable | Default | Description |
|----------|---------|-------------|
| ami_id | (auto) | AMI ID (auto-detected from marketplace) |
| instance_type | t3.medium | EC2 instance type |
| deployment_type | active-passive | single, active-passive, or active-active |
| use_spot_instance | false | Use Spot instances for cost savings |

### Network Variables

| Variable | Default | Description |
|----------|---------|-------------|
| vpc_id | (default VPC) | VPC ID |
| availability_zone | (auto) | AZ for deployment |

## AMI Auto-Detection

The module automatically finds the MayaNAS marketplace AMI using the product code.
You must first subscribe to MayaNAS on AWS Marketplace.

To use a specific AMI instead:
```hcl
ami_id = "ami-0123456789abcdef0"
```

## Outputs

| Output | Description |
|--------|-------------|
| node1_public_ip | Public IP of node 1 |
| vip_address | Virtual IP for NFS access |
| s3_bucket_name | S3 bucket name for data tiering |
| deployment_summary | Human-readable summary |

## NFS Mount Example

After deployment:

```bash
# Get VIP address
VIP=$(terraform output -raw vip_address)

# Mount on client (from same VPC)
sudo mount -t nfs ${VIP}:/mayanas-pool/share1 /mnt/mayanas
```

## Cost Estimation

Costs depend on:
- **Compute**: Instance type and hours
- **Storage**: S3 usage (pay for what you store)
- **EBS**: Metadata disk storage
- **Network**: Data transfer
- **Software**: MayaNAS license (metered via AWS Marketplace)

Use Spot instances (`use_spot_instance = true`) for 60-90% compute savings in dev/test.

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
