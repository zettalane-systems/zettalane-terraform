# MayaNAS Terraform Module for Microsoft Azure

Deploy MayaNAS enterprise NFS storage on Microsoft Azure.

## Overview

MayaNAS provides high-performance NFS storage with:
- ZFS reliability and data integrity
- Automatic tiering to Azure Blob Storage
- Active-Active HA for high availability
- NFSv3/NFSv4 and SMB protocol support

## Prerequisites

1. **Azure Subscription** with appropriate permissions
2. **Azure CLI** authenticated:
   ```bash
   az login
   az account set --subscription "your-subscription-id"
   ```
3. **Accept Marketplace Terms** (first time only):
   ```bash
   az vm image terms accept --publisher zettalane_systems-5254599 --offer mayanas-cloud-ent --plan mayanas-cloud-ent
   ```
4. **Terraform** >= 0.14

## Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/zettalane-systems/zettalane-terraform.git
   cd terraform/azure/mayanas
   ```

2. Create your configuration:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Edit `terraform.tfvars` with your settings:
   ```hcl
   resource_group_name = "rg-mayanas"
   location            = "eastus"
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
   ssh azureuser@$(terraform output -raw node1_public_ip)
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
| resource_group_name | Azure Resource Group name |

### Common Variables

| Variable | Default | Description |
|----------|---------|-------------|
| location | (auto) | Azure region |
| deployment_type | active-passive | single, active-passive, or active-active |
| vm_size | Standard_D4s_v3 | Azure VM size |
| metadata_disk_count | 1 | Metadata disks per deployment |
| use_spot_instance | false | Use Spot VMs for cost savings |

### SSH Key Configuration

Choose ONE method:

**Option 1: Direct SSH key content**
```hcl
ssh_public_key = "ssh-rsa AAAA..."
```

**Option 2: Azure Key Vault** (recommended for teams)
```hcl
ssh_key_vault_name         = "my-keyvault"
ssh_key_vault_secret_name  = "ssh-public-key"  # default
ssh_key_vault_resource_group = "rg-shared"     # optional, defaults to deployment RG
```

**Option 3: Azure SSH Public Key resource**
```hcl
ssh_key_resource_id = "/subscriptions/.../providers/Microsoft.Compute/sshPublicKeys/my-key"
```

| Variable | Default | Description |
|----------|---------|-------------|
| ssh_public_key | | Direct SSH public key content |
| ssh_key_vault_name | | Key Vault name containing SSH key |
| ssh_key_vault_secret_name | ssh-public-key | Secret name in Key Vault |
| ssh_key_vault_resource_group | | Resource group for Key Vault |
| ssh_key_resource_id | | Azure SSH Public Key resource ID |

### Network Variables

| Variable | Default | Description |
|----------|---------|-------------|
| vnet_name | (auto) | Virtual Network name |
| subnet_name | (auto) | Subnet name |
| ssh_cidr_blocks | ["0.0.0.0/0"] | CIDR ranges for SSH access |

## Outputs

| Output | Description |
|--------|-------------|
| node1_public_ip | Public IP of node 1 |
| vip_address | Virtual IP for NFS access |
| storage_account_name | Azure Storage Account name |
| deployment_summary | Human-readable summary |

## NFS Mount Example

After deployment:

```bash
# Get VIP address
VIP=$(terraform output -raw vip_address)

# Mount on client (from same VNet)
sudo mount -t nfs ${VIP}:/mayanas-pool/share1 /mnt/mayanas
```

## Cost Estimation

Costs depend on:
- **Compute**: VM size and hours
- **Storage**: Azure Blob Storage usage
- **Managed Disks**: Premium SSD for metadata
- **Network**: Egress traffic
- **Software**: MayaNAS license (metered via Azure Marketplace)

Use Spot VMs (`use_spot_instance = true`) for 60-90% compute savings in dev/test.

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
