# MayaNAS Terraform Module for AWS

Deploy MayaNAS enterprise NFS storage on Amazon Web Services.

## Overview

MayaNAS provides high-performance NFS storage with:
- ZFS reliability and data integrity
- Live ZFS zpool vdevs on Amazon S3 — the object store *is* the pool, not an archive tier
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
   git clone https://github.com/zettalane-systems/zettalane-terraform.git
   cd terraform/aws/mayanas
   ```

2. Create your configuration:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your settings:
   ```hcl
   key_pair_name    = "your-key-pair"
   assign_public_ip = true   # required unless your VPC has a NAT gateway or VPC endpoints
   # ami_id is auto-detected from marketplace subscription
   ```

   > The module is **private by default** (`assign_public_ip = false`), which is the
   > right posture for production. Set it `true` for the quick path above, or keep it
   > `false` and provide outbound reach yourself — on AWS that takes extra
   > infrastructure, see [Private-only deployments](#private-only-deployments).

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

   # SSH to node (the module builds the command for you)
   $(terraform output -raw ssh_command_primary)
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
| assign_public_ip | **false** | Give instances public IPs. Set `true` unless your VPC already provides outbound reach — see below |
| ssh_cidr_blocks | `["0.0.0.0/0"]` | CIDRs allowed to SSH |

### Private-only deployments

Private-only is the module default and a supported configuration. What it needs from
you is outbound reach: this module creates **no NAT gateway and no VPC endpoints**, so
that connectivity is yours to provide.

**Please consult a ZettaLane Systems support engineer before deploying without public
IPs** — support@zettalane.com.

> **On AWS, treat this as an expert option.** Setting `assign_public_ip = false` here
> produces a **non-functional cluster** unless the VPC you deploy into already provides
> outbound reach — set `vpc_id` to one that does. On GCP and Azure the equivalent is
> straightforward; on AWS it is not.

On AWS this is the one cloud where it takes real work and real money. GCP and Azure
give private instances control-plane access for free, so private-only there is close to
a flag; on AWS plan for the components below, or use a public IP for evaluation and
non-production clusters.

This is not only about SSH. The nodes call `ec2:AssignPrivateIpAddresses` to attach
each VIP as a secondary private IP; IMDS supplies only credentials, so the call still
has to reach `ec2.<region>.amazonaws.com`. Without a path there the VIPs never come up
and the cluster is non-functional **even though `terraform apply` reports success**.
The nodes also need S3, because the pool's data vdevs live there.

| what you need | option | cost |
|---|---|---|
| S3 for the pool's data vdevs | S3 **gateway** endpoint | free |
| EC2 API for VIP assignment | EC2 **interface** endpoint | ~$7/mo per AZ + data |
| everything, simplest | NAT gateway | ~$32/mo + data |

AWS is the outlier here: GCP (Private Google Access), Azure (Service Endpoints) and
OCI (Service Gateway) all provide private control-plane access at no charge.

## Choosing an AMI

**Marketplace (metered).** Leave `ami_id` empty and the module finds the MayaNAS
marketplace AMI by product code. Requires a Marketplace subscription first; usage is
metered through it.

**Community (free).** The Community Edition images carry **no product code**, so no
subscription and no terms acceptance are needed — you pay only for EC2, EBS and S3.
They are not found by product code, so pass the id explicitly. AMIs are regional, and
AWS has no image-family primitive, so resolve the newest by name prefix:

```bash
aws ec2 describe-images --owners <publisher-account> --region <region> \
  --filters "Name=name,Values=mayanas-community-*" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text
```

**Any specific AMI:**
```hcl
ami_id = "ami-0123456789abcdef0"
```

## Outputs

| Output | Description |
|--------|-------------|
| node1_public_ip | Public IP of node 1 (`null` when `assign_public_ip = false`) |
| node1_private_ip | Private IP of node 1 |
| ssh_command_primary | Ready-made SSH command for node 1 |
| vip_address | Virtual IP for NFS access |
| vip_address_2 | Second VIP (active-active only) |
| s3_bucket_names | S3 buckets used as pool vdevs (list) |
| nfs_test_shares | NFS share paths, one per node — used by automated tests |
| deployment_summary | Human-readable summary |

`terraform output` lists them all.

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
- **Software**: MayaNAS license — metered via AWS Marketplace, or **free** on a Community Edition AMI (no product code)

Use Spot instances (`use_spot_instance = true`) for 60-90% compute savings in dev/test.

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
