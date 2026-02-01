# MayaNAS Terraform Module for Google Cloud

Deploy MayaNAS enterprise NFS storage on Google Cloud Platform.

## Overview

MayaNAS provides high-performance NFS storage with:
- ZFS reliability and data integrity
- Automatic tiering to Google Cloud Storage
- Active-Active HA for high availability
- NFSv3/NFSv4 and SMB protocol support

## Prerequisites

1. **GCP Project** with billing enabled
2. **APIs enabled:**
   ```bash
   gcloud services enable compute.googleapis.com
   gcloud services enable storage.googleapis.com
   gcloud services enable iam.googleapis.com
   ```
3. **Terraform** >= 0.14
4. **gcloud CLI** authenticated

## Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/zettalane-systems/terraform.git
   cd terraform/gcp/mayanas
   ```

2. Create your configuration:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your settings:
   ```hcl
   project_id = "your-gcp-project-id"
   region     = "us-central1"
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

   # Get Web UI password
   terraform output -raw mayanas_password
   ```

## Deployment Types

| Type | Nodes | Use Case |
|------|-------|----------|
| single | 1 | Development, testing |
| active-passive | 2 | HA with failover |
| active-active | 2 | HA with load balancing (default) |

## Configuration

### Required Variables

| Variable | Description |
|----------|-------------|
| project_id | GCP project ID |

### Common Variables

| Variable | Default | Description |
|----------|---------|-------------|
| region | us-central1 | GCP region |
| deployment_type | active-active | single, active-passive, or active-active |
| machine_type | n1-standard-2 | GCE machine type |
| bucket_count | 1 | GCS buckets per node (1-12) |
| metadata_disk_size_gb | 100 | Metadata disk size |
| use_spot_vms | false | Use Spot VMs for cost savings |

### Network Variables

| Variable | Default | Description |
|----------|---------|-------------|
| network_name | default | VPC network name |
| subnet_name | (auto) | Subnet name |
| ssh_source_ranges | ["0.0.0.0/0"] | CIDR ranges for SSH access |

## Outputs

| Output | Description |
|--------|-------------|
| node1_external_ip | External IP of node 1 |
| vip_node1_address | Virtual IP for NFS access |
| ssh_command_node1 | SSH command to connect |
| web_ui_url_node1 | Web UI URL |
| mayanas_password | Web UI password (sensitive) |
| gcs_bucket_names | Created GCS bucket names |
| deployment_summary | Human-readable summary |

## NFS Mount Example

After deployment:

```bash
# Get VIP address
VIP=$(terraform output -raw vip_node1_address)

# Mount on client (from same VPC)
sudo mount -t nfs ${VIP}:/mayanas-pool/share1 /mnt/mayanas
```

## Cost Estimation

Costs depend on:
- **Compute**: Machine type and hours
- **Storage**: GCS usage (pay for what you store)
- **Metadata disks**: Persistent SSD
- **Network**: Egress traffic
- **Software**: MayaNAS license (metered via GCP Marketplace)

Use Spot VMs (`use_spot_vms = true`) for 60-90% compute savings in dev/test.

## Cleanup

```bash
terraform destroy
```

Note: Set `force_destroy_buckets = true` if buckets contain data.

## Support

- Documentation: https://docs.zettalane.com
- Issues: https://github.com/zettalane-systems/terraform/issues
- Email: support@zettalane.com

## License

Apache 2.0 - See [LICENSE](../../LICENSE)
