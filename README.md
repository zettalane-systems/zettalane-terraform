# ZettaLane Terraform Modules

Terraform modules for deploying ZettaLane storage solutions on public clouds.

[![Demo Video](https://img.shields.io/badge/Demo-YouTube-red)](https://youtu.be/skYywjF4w3A)

## Products

### MayaNAS

Enterprise NFS storage with ZFS reliability and cloud tiering.

| Cloud | Path | Status |
|-------|------|--------|
| GCP | [gcp/mayanas](./gcp/mayanas) | Available |
| AWS | [aws/mayanas](./aws/mayanas) | Available |
| Azure | [azure/mayanas](./azure/mayanas) | Available |

### MayaScale

High-performance NVMe block storage for databases and AI workloads.

| Cloud | Path | Status |
|-------|------|--------|
| GCP | [gcp/mayascale](./gcp/mayascale) | Available |
| AWS | [aws/mayascale](./aws/mayascale) | Available |
| Azure | [azure/mayascale](./azure/mayascale) | Available |

## Prerequisites

**Terraform** >= 1.0
```bash
# macOS
brew install terraform

# Linux (Ubuntu/Debian)
sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform

# Windows (WSL2) - use Linux instructions above
```

**Cloud Authentication**

| Cloud | Command |
|-------|---------|
| GCP | `gcloud auth application-default login` |
| AWS | `aws configure` |
| Azure | `az login` |

## Quick Start

```bash
# Clone the repo
git clone https://github.com/zettalane-systems/zettalane-terraform.git
cd zettalane-terraform

# MayaNAS - NFS storage
./validate-mayanas.sh --cloud gcp --project-id my-project --zone us-central1-a

# MayaScale - NVMe block storage
./validate-mayascale.sh --cloud gcp --project-id my-project --zone us-central1-a
```

## Validation Scripts

### MayaNAS (validate-mayanas.sh)

Deploys MayaNAS storage + client VM, runs NFS tests:

```bash
./validate-mayanas.sh --cloud PROVIDER [OPTIONS]

REQUIRED:
    --cloud PROVIDER          Cloud provider: gcp, aws, or azure

GCP OPTIONS:
    --project-id PROJECT      GCP project ID (required)
    --zone ZONE               GCP zone (default: us-central1-a)

AWS OPTIONS:
    --key-pair KEY_PAIR       AWS EC2 Key Pair name (required)
    --zone AZ                 AWS availability zone (optional)

AZURE OPTIONS:
    --resource-group RG       Azure resource group name (required)
    --location LOCATION       Azure location (e.g., eastus)
    (For Key Vault SSH keys, see azure/mayanas/README.md)

COMMON OPTIONS:
    -n, --name NAME           Deployment name (default: demo)
    --cluster TYPE            Cluster type: single, ha (default: single)
    -t, --tier TIER           Performance tier: basic, standard, performance, ultra (default: standard)
    -m, --machine-type TYPE   Override machine type (cloud-specific)
    -b, --bucket-count COUNT  Number of cloud storage buckets (default: 1, use 8-10 for high throughput)
    --ssh-key PATH            SSH public key file (default: ~/.ssh/id_rsa.pub)
    --spot                    Use spot/preemptible instances (default)
    --no-spot                 Use on-demand instances
    --skip-deploy             Skip terraform apply, validate existing deployment
    --skip-client             Skip client deployment, storage-only validation
    -d, --destroy             Destroy all resources and exit
```

### Cluster Types

| Type | Description |
|------|-------------|
| single | Single node NFS server |
| ha | High availability (active-active with dual VIPs) |

### Performance Tiers

| Tier | GCP | AWS | Azure |
|------|-----|-----|-------|
| basic | n2-standard-4 | c6in.xlarge | Standard_D4s_v5 |
| standard | n2-standard-8 | c6in.2xlarge | Standard_D8s_v5 |
| performance | n2-standard-16 | c6in.4xlarge | Standard_D16s_v5 |
| ultra | n2-standard-32 | c6in.8xlarge | Standard_D32s_v5 |

### Performance Tuning

**Bucket Count (`-b`)**: MayaNAS stripes data across cloud object storage buckets. More buckets = higher aggregate throughput.

| Workload | Recommended Buckets |
|----------|---------------------|
| Development/test | 1 (default) |
| Production | 4-6 |
| High throughput (performance/ultra tier) | 8-10 |

For maximum throughput, use `-t ultra -b 10` or `-t performance -b 8`.

### SSH Access

**SSH Key**: Provide your public key with `--ssh-key PATH` (default: `~/.ssh/id_rsa.pub`).

**SSH Usernames by Cloud:**

| Cloud | MayaNAS | MayaScale |
|-------|---------|-----------|
| GCP | `mayanas` | `mayascale` |
| AWS | `ec2-user` | `ec2-user` |
| Azure | `azureuser` | `azureuser` |

**Connect to storage node:**
```bash
# Get IP from terraform output
cd gcp/mayanas && terraform output storage_ip

# SSH to storage
ssh mayanas@<storage_ip>
```

### Examples

```bash
# GCP - standard tier (quick test)
./validate-mayanas.sh --cloud gcp --project-id my-project --zone us-central1-a

# GCP - high performance (production workloads)
./validate-mayanas.sh --cloud gcp --project-id my-project --zone us-central1-a -t performance -b 8

# GCP - HA cluster with ultra tier (maximum throughput)
./validate-mayanas.sh --cloud gcp --project-id my-project --zone us-central1-a --cluster ha -t ultra -b 10

# AWS - performance tier
./validate-mayanas.sh --cloud aws --key-pair my-keypair -t performance -b 8

# Azure - standard deployment
./validate-mayanas.sh --cloud azure --resource-group mayanas-rg --location eastus

# Destroy all resources
./validate-mayanas.sh --cloud gcp --project-id my-project -d
```

### Rerunning Tests

Run the script again to rerun tests on existing deployment (automatically detected).
Run with `-d` to destroy first, then run again for a fresh deployment.

### MayaScale (validate-mayascale.sh)

Deploys MayaScale NVMe-oF storage + client VM, runs block storage tests:

```bash
./validate-mayascale.sh --cloud gcp --project-id my-project --zone us-central1-a
./validate-mayascale.sh --cloud aws --key-pair my-keypair
./validate-mayascale.sh --cloud azure --resource-group mayascale-rg --location eastus
```

Options are similar to validate-mayanas.sh. Run `./validate-mayascale.sh --help` for details.

## Manual Deployment

If you prefer to run terraform directly:

```bash
cd gcp/mayanas
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings
terraform init
terraform apply
```

## Pricing

These modules deploy metered images from cloud marketplaces. You will be billed:

1. **Infrastructure costs** - Compute, storage, network (paid to cloud provider)
2. **Software license** - MayaNAS/MayaScale usage fee (paid via marketplace)

See each cloud's marketplace listing for current pricing.

## Support

- Documentation: https://zettalane.com
- Issues: https://github.com/zettalane-systems/zettalane-terraform/issues
- Email: support@zettalane.com

## License

Apache 2.0 - See [LICENSE](./LICENSE)
