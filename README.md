# ZettaLane Terraform Modules

Terraform modules for deploying ZettaLane storage solutions on public clouds.

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
| GCP | [gcp/mayascale](./gcp/mayascale) | Coming soon |
| AWS | [aws/mayascale](./aws/mayascale) | Coming soon |

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
git clone https://github.com/zettalane-systems/terraform.git
cd terraform

# Deploy and validate with one command
./validate-mayanas.sh --cloud gcp --project-id my-project --zone us-central1-a
```

## Validation Script

The validation script deploys MayaNAS storage + client VM, runs NFS tests:

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
    -t, --tier TIER           Performance tier: basic, standard, performance (default: standard)
    -m, --machine-type TYPE   Override machine type (cloud-specific)
    -b, --bucket-count COUNT  Number of cloud storage buckets (default: 1)
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
| basic | n2-standard-4 | c6in.xlarge | Standard_D4s_v3 |
| standard | n2-standard-8 | c6in.2xlarge | Standard_D8s_v3 |
| performance | n2-standard-16 | c6in.4xlarge | Standard_D16s_v3 |

### Examples

```bash
# GCP with standard tier
./validate-mayanas.sh --cloud gcp --project-id my-project --zone us-central1-a

# AWS with performance tier
./validate-mayanas.sh --cloud aws --key-pair my-keypair --tier performance

# Azure with custom machine type
./validate-mayanas.sh --cloud azure --resource-group mayanas-rg --location eastus -m Standard_D32s_v3

# GCP with HA cluster
./validate-mayanas.sh --cloud gcp --project-id my-project --zone us-central1-a --cluster ha

# GCP with multiple buckets
./validate-mayanas.sh --cloud gcp --project-id my-project --zone us-central1-a -b 4

# Destroy all resources
./validate-mayanas.sh --cloud gcp --project-id my-project -d
```

### Rerunning Tests

Run the script again to rerun tests on existing deployment (automatically detected).
Run with `-d` to destroy first, then run again for a fresh deployment.

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

- Documentation: https://docs.zettalane.com
- Issues: https://github.com/zettalane-systems/terraform/issues
- Email: support@zettalane.com

## License

Apache 2.0 - See [LICENSE](./LICENSE)
