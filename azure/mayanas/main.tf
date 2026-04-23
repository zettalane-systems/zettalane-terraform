# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Configure the Azure Provider
provider "azurerm" {
  subscription_id = var.subscription_id

  # Resource provider registrations (replaces deprecated skip_provider_registration)
  # Automatically register required Azure resource providers
  resource_provider_registrations = "core"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# Generate unique suffix for resources
resource "random_id" "suffix" {
  byte_length = 4
}

# Generate random password for MayaNAS instances
resource "random_password" "mayanas_password" {
  length  = 16
  special = true
  upper   = true
  lower   = true
  numeric = true
}

# Generate cluster resource IDs for unique naming
resource "random_integer" "resource_id" {
  min = 1
  max = 255
}

resource "random_integer" "peer_resource_id" {
  min = 1
  max = 255
}

# Generate deployment identifier for unique resource naming
resource "random_id" "deployment" {
  byte_length = 4
}

# Get current client configuration
data "azurerm_client_config" "current" {}

# Optional: Get SSH key from Key Vault if specified
data "azurerm_key_vault_secret" "ssh_key" {
  count        = var.ssh_key_vault_id != "" ? 1 : 0
  name         = basename(var.ssh_key_vault_id)
  key_vault_id = dirname(var.ssh_key_vault_id)
}

# Optional: Get SSH key from Azure SSH Public Key resource if specified
data "azurerm_ssh_public_key" "ssh_key" {
  count               = var.ssh_key_resource_id != "" ? 1 : 0
  name                = basename(var.ssh_key_resource_id)
  resource_group_name = split("/", var.ssh_key_resource_id)[4]
}

# Validation: Ensure only one SSH key method is specified
locals {
  ssh_methods_count = (
    (var.ssh_public_key != "" ? 1 : 0) +
    (var.ssh_key_vault_id != "" ? 1 : 0) +
    (var.ssh_key_resource_id != "" ? 1 : 0)
  )
}

# Validation check
resource "null_resource" "ssh_key_validation" {
  count = local.ssh_methods_count != 1 ? 1 : 0

  provisioner "local-exec" {
    command = "echo 'ERROR: Exactly one SSH key method must be specified: ssh_public_key, ssh_key_vault_id, or ssh_key_resource_id' && exit 1"
  }
}

# Check if resource group exists (only when name is specified)
data "external" "resource_group_exists" {
  count = var.resource_group_name != "" ? 1 : 0
  program = ["bash", "-c", <<-EOF
    if az group show --name "${var.resource_group_name}" >/dev/null 2>&1; then
      echo '{"exists":"true"}'
    else
      echo '{"exists":"false"}'
    fi
  EOF
  ]
}

locals {
  # Determine if we should use existing resource group
  use_existing_rg = var.resource_group_name != "" && length(data.external.resource_group_exists) > 0 && data.external.resource_group_exists[0].result.exists == "true"
  create_new_rg = var.resource_group_name == "" || (length(data.external.resource_group_exists) > 0 && data.external.resource_group_exists[0].result.exists == "false")
}

# Use existing resource group if it exists
data "azurerm_resource_group" "existing" {
  count = local.use_existing_rg ? 1 : 0
  name  = var.resource_group_name
}

# Create new resource group if it doesn't exist or name not specified
resource "azurerm_resource_group" "mayanas" {
  count    = local.create_new_rg ? 1 : 0
  name     = var.resource_group_name != "" ? var.resource_group_name : "rg-mayanas-${var.cluster_name != "" ? var.cluster_name : "cluster"}-${random_id.deployment.hex}"
  location = var.location != "" ? var.location : "eastus"
  tags     = var.tags

  lifecycle {
    ignore_changes = [tags]
  }
}

# Auto-detect or create virtual network
# Commented out auto-detect - requires specific vnet name
# data "azurerm_virtual_network" "existing" {
#   count               = var.vnet_name == "" ? 1 : 0
#   name                = "default-vnet"  # Would need actual vnet name
#   resource_group_name = local.resource_group_name
# }

data "azurerm_virtual_network" "selected" {
  count               = var.vnet_name != "" ? 1 : 0
  name                = var.vnet_name
  resource_group_name = local.resource_group_name
}

resource "azurerm_virtual_network" "mayanas" {
  count               = var.vnet_name == "" ? 1 : 0  # Always create if no vnet specified
  name                = "vnet-mayanas-${random_id.deployment.hex}"
  address_space       = var.vnet_address_space
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

# Auto-detect or create subnet
data "azurerm_subnet" "selected" {
  count                = var.subnet_name != "" ? 1 : 0
  name                 = var.subnet_name
  virtual_network_name = local.virtual_network_name
  resource_group_name  = local.resource_group_name
}

resource "azurerm_subnet" "mayanas" {
  count                = var.subnet_name == "" ? 1 : 0
  name                 = "subnet-mayanas-${random_id.deployment.hex}"
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.virtual_network_name
  address_prefixes     = var.subnet_address_prefixes
}

# Availability zones for HA deployment (equivalent to GCP multi-zone)
# Most Azure regions support zones 1, 2, 3
locals {
  default_zones = ["1", "2", "3"]
}

locals {
  # Resource group selection: use existing data source if found, otherwise use created resource
  resource_group = local.use_existing_rg ? data.azurerm_resource_group.existing[0] : azurerm_resource_group.mayanas[0]
  resource_group_name = local.resource_group.name

  # Network configuration
  virtual_network_name = var.vnet_name != "" ? var.vnet_name : azurerm_virtual_network.mayanas[0].name
  
  subnet_id = var.subnet_name != "" ? data.azurerm_subnet.selected[0].id : azurerm_subnet.mayanas[0].id

  # Zone configuration with improved auto-selection logic
  # Priority: 1) User-specified zones 2) Auto-select if multi_zone=true 3) No zones (availability set)
  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : (
    var.multi_zone ? (
      # Auto-select 2 zones for regions that support availability zones
      contains(["eastus", "eastus2", "centralus", "westeurope", "northeurope", "southeastasia", "westus2", "uksouth", "japaneast", "australiaeast"], local.resource_group.location) ? 
      slice(local.default_zones, 0, 2) : []
    ) : []
  )
  
  node1_zone = length(local.availability_zones) > 0 ? local.availability_zones[0] : null
  node2_zone = length(local.availability_zones) > 1 ? local.availability_zones[1] : local.node1_zone

  # Deployment configuration
  cluster_name = var.cluster_name != "" ? var.cluster_name : "mayanas-${random_id.deployment.hex}"
  
  # Instance count based on deployment type
  node_count = var.deployment_type == "single" ? 1 : 2
  
  # VIP configuration with auto-generation
  # For custom-route: VIPs outside subnet range to avoid routing conflicts
  # For load-balancer: VIPs within subnet range for Azure LB frontend
  subnet_cidr = azurerm_subnet.mayanas[0].address_prefixes[0]
  subnet_parts = split(".", split("/", local.subnet_cidr)[0])
  
  # Generate VIP outside subnet by using different third octet
  # E.g., for 10.0.1.0/24 -> 10.0.100.x, for 192.168.1.0/24 -> 192.168.100.x
  vip_network_base = format("%s.%s.100", local.subnet_parts[0], local.subnet_parts[1])
  
  vip_address_final = var.vip_address != "" ? var.vip_address : (
    var.vip_mechanism == "custom-route" ? 
      format("%s.%d", local.vip_network_base, 100 + (local.resource_id % 155)) :
      cidrhost(local.subnet_cidr, 100)
  )
  vip_address_2_final = var.deployment_type == "active-active" && var.vip_address_2 != "" ? var.vip_address_2 : (
    var.deployment_type == "active-active" ? (
      var.vip_mechanism == "custom-route" ?
        format("%s.%d", local.vip_network_base, 101 + (local.resource_id % 154)) :
        cidrhost(local.subnet_cidr, 101)
    ) : ""
  )

  # Metadata disk configuration with auto-sizing
  metadata_disk_size_final = var.metadata_disk_size_gb
  
  # Auto-select disk type based on deployment pattern (following GCP pattern)
  # Single zone: LRS (local redundancy, optimal performance)
  # Multi-zone HA: ZRS (cross-zone shared storage for failover)
  metadata_disk_type_final = var.metadata_disk_type != "" ? var.metadata_disk_type : (
    var.multi_zone || length(local.availability_zones) > 1 ? "Premium_ZRS" : "Premium_LRS"
  )

  # Auto-select storage account type based on deployment pattern
  # Single zone: LRS (local redundancy, available in all regions)
  # Multi-zone HA: ZRS (cross-zone redundancy for shared storage)
  storage_account_type_final = var.multi_zone || length(local.availability_zones) > 1 ? "Standard_ZRS" : "Standard_LRS"

  # Storage account name (DNS compliant)
  storage_account_name = "st${replace(lower(local.cluster_name), "-", "")}${substr(random_id.deployment.hex, 0, 6)}"
  
  # Resource IDs for compatibility with AWS template
  resource_id = random_integer.resource_id.result
  peer_resource_id = random_integer.peer_resource_id.result
  
  # SSH key selection (Azure SSH Public Key, Key Vault, or direct)
  ssh_public_key_final = var.ssh_key_resource_id != "" ? data.azurerm_ssh_public_key.ssh_key[0].public_key : (var.ssh_key_vault_id != "" ? data.azurerm_key_vault_secret.ssh_key[0].value : var.ssh_public_key)
  
  # Container count calculation (matching GCP/AWS pattern)
  total_bucket_count = var.deployment_type == "active-active" ? var.bucket_count * 2 : var.bucket_count

  # Common tags
  common_tags = merge(var.tags, {
    DeploymentType = var.deployment_type
    Environment    = var.environment
    ClusterName    = local.cluster_name
    MayaNAS        = "true"
  })
}

# Startup script template (only primary node needs startup script, matching AWS/GCP pattern)
locals {
  startup_script_primary = templatefile("${path.module}/startup.sh.tpl", {
    cluster_name                = local.cluster_name
    deployment_type            = var.deployment_type
    node_role                  = var.deployment_type == "active-active" ? "node1" : "primary"
    vip_address                = local.vip_address_final
    vip_address_2              = local.vip_address_2_final
    bucket_count               = var.bucket_count
    node_count                 = local.node_count
    peer_zone                  = local.node_count > 1 ? (local.node2_zone != null ? local.node2_zone : "") : ""
    metadata_disk_count        = var.metadata_disk_count
    storage_size_gb            = var.storage_size_gb
    resource_id                = local.resource_id
    peer_resource_id           = local.peer_resource_id
    availability_zone          = local.node1_zone != null ? local.node1_zone : ""
    azure_region               = local.resource_group.location
    resource_group_name        = local.resource_group_name
    secondary_resource_group_name = local.resource_group_name  # Same resource group in Azure
    secondary_private_ip       = local.node_count > 1 ? azurerm_network_interface.mayanas[1].ip_configuration[0].private_ip_address : ""
    secondary_instance_name    = local.node_count > 1 ? (var.deployment_type == "active-active" ? "${local.cluster_name}-mayanas-node2-${random_id.deployment.hex}" : "${local.cluster_name}-secondary-${random_id.deployment.hex}") : ""
    bucket_names               = join(" ", azurerm_storage_container.mayanas[*].name)
    metadata_disk_names        = join(" ", [for i, disk in azurerm_managed_disk.metadata : disk.name if i % local.node_count == 0])
    s3_access_key              = azurerm_storage_account.mayanas.name  # Storage account name (key retrieved at runtime via managed identity)
    ssh_public_key             = local.ssh_public_key_final
    # For active-active: split buckets/disks between nodes (first half = node1, second half = node2)
    # For other deployments: all buckets/disks for node1, empty for node2
    bucket_node1               = var.deployment_type == "active-active" ? join(" ", slice(azurerm_storage_container.mayanas[*].name, 0, var.bucket_count)) : join(" ", azurerm_storage_container.mayanas[*].name)
    bucket_node2               = var.deployment_type == "active-active" ? join(" ", slice(azurerm_storage_container.mayanas[*].name, var.bucket_count, local.total_bucket_count)) : ""
    metadata_disk_node1        = var.deployment_type == "active-active" ? azurerm_managed_disk.metadata[0].name : ""
    metadata_disk_node2        = var.deployment_type == "active-active" && local.node_count > 1 ? azurerm_managed_disk.metadata[1].name : ""
    metadata_disk_size_gb      = var.metadata_disk_size_gb
    project_id                 = local.resource_group_name  # Azure equivalent: resource group name
    subnet_cidr = azurerm_subnet.mayanas[0].address_prefixes[0]
    shares                     = jsonencode(var.shares)
  })
}

# Proximity Placement Group for HA deployments (reduces latency)
resource "azurerm_proximity_placement_group" "mayanas" {
  count               = var.enable_proximity_placement_group && local.node_count > 1 ? 1 : 0
  name                = "ppg-mayanas-${local.cluster_name}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  tags                = local.common_tags
}

# Network Security Group
resource "azurerm_network_security_group" "mayanas" {
  name                = "nsg-mayanas-${local.cluster_name}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  tags                = local.common_tags

  # SSH access
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.ssh_cidr_blocks
    destination_address_prefix = "*"
  }

  # NFS access (internal)
  security_rule {
    name                       = "NFS"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "2049"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  # Load Balancer health probe (for Azure LB VIP mechanism)
  security_rule {
    name                       = "HealthProbe"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "61000"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Internal cluster communication
  security_rule {
    name                       = "InternalCluster"
    priority                   = 1004
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

# Route Table for Custom Route VIP mechanism (single shared table)
resource "azurerm_route_table" "mayanas" {
  count                         = var.vip_mechanism == "custom-route" && local.node_count > 1 ? 1 : 0
  name                          = "mayanas-route-table"
  location                      = local.resource_group.location
  resource_group_name          = local.resource_group_name
  bgp_route_propagation_enabled = true
  tags                         = local.common_tags
}

# Associate route table with subnet
resource "azurerm_subnet_route_table_association" "mayanas" {
  count          = var.vip_mechanism == "custom-route" && local.node_count > 1 ? 1 : 0
  subnet_id      = local.subnet_id
  route_table_id = azurerm_route_table.mayanas[0].id
}

# Load Balancer for Load Balancer VIP mechanism
resource "azurerm_public_ip" "lb" {
  count               = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? 1 : 0
  name                = "pip-lb-mayanas-${local.cluster_name}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                = "Standard"
  tags               = local.common_tags
}

resource "azurerm_lb" "mayanas" {
  count               = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? 1 : 0
  name                = "lb-mayanas-${local.cluster_name}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  sku                = "Standard"
  tags               = local.common_tags

  frontend_ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address           = local.vip_address_final
  }

  frontend_ip_configuration {
    name                 = "external"
    public_ip_address_id = azurerm_public_ip.lb[0].id
  }
}

# Load Balancer Backend Pool
resource "azurerm_lb_backend_address_pool" "mayanas" {
  count           = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? 1 : 0
  loadbalancer_id = azurerm_lb.mayanas[0].id
  name            = "mayanas-backend"
}

# Health Probe on port 61000 (expected by AzureLB.resource)
resource "azurerm_lb_probe" "mayanas" {
  count           = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? 1 : 0
  loadbalancer_id = azurerm_lb.mayanas[0].id
  name            = "mayanas-health-probe"
  port            = 61000
  protocol        = "Tcp"
  interval_in_seconds = 15
  number_of_probes    = 2
}

# Load Balancer Rule
resource "azurerm_lb_rule" "nfs" {
  count                          = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? 1 : 0
  loadbalancer_id                = azurerm_lb.mayanas[0].id
  name                           = "NFS"
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.mayanas[0].id]
  probe_id                       = azurerm_lb_probe.mayanas[0].id
  floating_ip_enabled            = true
  idle_timeout_in_minutes        = 30
}

# ZRS Managed Disks for metadata (cross-zone shared storage like GCP regional disks)
resource "azurerm_managed_disk" "metadata" {
  count                = var.deployment_type == "active-active" ? local.node_count * var.metadata_disk_count : var.metadata_disk_count
  name                 = "disk-metadata-${local.cluster_name}-${count.index % local.node_count + 1}-${floor(count.index / local.node_count) + 1}-${random_id.suffix.hex}"
  location             = local.resource_group.location
  resource_group_name  = local.resource_group_name
  storage_account_type = local.metadata_disk_type_final
  create_option        = "Empty"
  disk_size_gb         = local.metadata_disk_size_final
  
  # Zone setting: null for ZRS (cross-zone), specific zone for LRS (single-zone)
  zone = local.metadata_disk_type_final == "Premium_ZRS" || local.metadata_disk_type_final == "StandardSSD_ZRS" ? null : (count.index % local.node_count == 0 ? local.node1_zone : local.node2_zone)
  
  # Ultra Disk performance settings
  disk_iops_read_write = var.use_ultra_disks ? var.ultra_disk_iops : null
  disk_mbps_read_write = var.use_ultra_disks ? var.ultra_disk_throughput_mbps : null
  
  tags = merge(local.common_tags, {
    Purpose = "metadata"
    Node    = "node${count.index % local.node_count + 1}"
    Index   = tostring(floor(count.index / local.node_count) + 1)
  })
}

# Storage Account for object storage
resource "azurerm_storage_account" "mayanas" {
  name                     = local.storage_account_name
  resource_group_name      = local.resource_group_name
  location                 = local.resource_group.location
  account_tier             = split("_", local.storage_account_type_final)[0]
  account_replication_type = split("_", local.storage_account_type_final)[1]
  account_kind            = "StorageV2"
  
  # Advanced features
  https_traffic_only_enabled     = true
  min_tls_version               = "TLS1_2"
  allow_nested_items_to_be_public = false
  
  tags = local.common_tags
}

# Create blob containers based on bucket_count (like AWS S3 buckets / GCP buckets)
# For active-active: bucket_count * 2, otherwise bucket_count
resource "azurerm_storage_container" "mayanas" {
  count = local.total_bucket_count
  name                  = "${local.cluster_name}-data-${count.index}-${random_id.deployment.hex}"
  storage_account_id    = azurerm_storage_account.mayanas.id
  container_access_type = "private"
}

# Public IP addresses for VMs (conditional on assign_public_ip)
resource "azurerm_public_ip" "mayanas" {
  count               = var.assign_public_ip ? local.node_count : 0
  name                = "pip-mayanas-node${count.index + 1}-${local.cluster_name}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  tags               = local.common_tags
}

# Network Interfaces with Accelerated Networking
resource "azurerm_network_interface" "mayanas" {
  count                         = local.node_count
  name                          = "nic-mayanas-node${count.index + 1}-${local.cluster_name}"
  location                      = local.resource_group.location
  resource_group_name          = local.resource_group_name
  accelerated_networking_enabled = var.enable_accelerated_networking
  tags                         = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.assign_public_ip ? azurerm_public_ip.mayanas[count.index].id : null
  }
}

# Associate Network Security Group
resource "azurerm_network_interface_security_group_association" "mayanas" {
  count                     = local.node_count
  network_interface_id      = azurerm_network_interface.mayanas[count.index].id
  network_security_group_id = azurerm_network_security_group.mayanas.id
}

# Associate with Load Balancer Backend Pool
resource "azurerm_network_interface_backend_address_pool_association" "mayanas" {
  count                   = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? local.node_count : 0
  network_interface_id    = azurerm_network_interface.mayanas[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.mayanas[0].id
}

# VM Image data source (auto-detect MayaNAS image)
data "azurerm_images" "mayanas" {
  count               = var.vm_image_id == "" ? 1 : 0
  resource_group_name = "rg-mayanas-images"  # Assumed image resource group
  # Remove name_regex - not supported in current provider
}

# Virtual Machines with System-assigned Managed Identity
resource "azurerm_linux_virtual_machine" "mayanas" {
  count                           = local.node_count
  name                            = var.deployment_type == "active-active" ? "${local.cluster_name}-mayanas-node${count.index + 1}-${random_id.deployment.hex}" : (count.index == 0 ? "${local.cluster_name}-primary-${random_id.deployment.hex}" : "${local.cluster_name}-secondary-${random_id.deployment.hex}")
  location                        = local.resource_group.location
  resource_group_name            = local.resource_group_name
  size                           = var.vm_size
  zone                           = count.index == 0 ? local.node1_zone : local.node2_zone
  disable_password_authentication = true
  
  # Proximity Placement Group for HA
  proximity_placement_group_id = var.enable_proximity_placement_group && local.node_count > 1 ? azurerm_proximity_placement_group.mayanas[0].id : null
  
  # Spot instance configuration
  priority        = var.use_spot_instance ? "Spot" : "Regular"
  eviction_policy = var.use_spot_instance ? "Deallocate" : null
  max_bid_price   = var.use_spot_instance ? var.spot_max_price : null

  network_interface_ids = [azurerm_network_interface.mayanas[count.index].id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  # Use custom image ID if specified, otherwise use marketplace image
  source_image_id = var.vm_image_id != "" ? var.vm_image_id : null

  # Azure Marketplace MayaNAS image
  dynamic "source_image_reference" {
    for_each = var.vm_image_id == "" ? [1] : []
    content {
      publisher = "zettalane_systems-5254599"
      offer     = "mayanas-cloud-ent"
      sku       = "mayanas-cloud-ent"
      version   = "latest"
    }
  }

  # Marketplace plan (required for marketplace images)
  dynamic "plan" {
    for_each = var.vm_image_id == "" ? [1] : []
    content {
      name      = "mayanas-cloud-ent"
      publisher = "zettalane_systems-5254599"
      product   = "mayanas-cloud-ent"
    }
  }

  admin_username = "azureuser"

  admin_ssh_key {
    username   = "azureuser"
    public_key = local.ssh_public_key_final
  }

  # System-assigned Managed Identity (equivalent to AWS IAM role)
  identity {
    type = "SystemAssigned"
  }

  # Enable Ultra SSD capability if using Ultra Disks
  additional_capabilities {
    ultra_ssd_enabled = var.use_ultra_disks
  }

  # Security Profile for Trusted Launch (required for custom kernels)
  secure_boot_enabled = !var.disable_secure_boot
  vtpm_enabled        = !var.disable_vtpm

  tags = merge(local.common_tags, {
    Name = "mayanas-node${count.index + 1}"
    Role = count.index == 0 ? "primary" : "secondary"
  })

  # Custom data for initialization (only primary node gets startup script, matching AWS/GCP pattern)
  custom_data = count.index == 0 ? base64encode(local.startup_script_primary) : null

  # Explicit dependencies for proper destruction order
  depends_on = [
    azurerm_network_interface_security_group_association.mayanas,
    azurerm_storage_account.mayanas,
    azurerm_managed_disk.metadata
  ]
}

# Attach metadata disks based on deployment type
# Single/Active-passive: Attach to primary node (cluster setup handles failover for active-passive)
# Active-active: Do NOT attach here - cluster setup script handles sequential attachment for predictable device ordering
resource "azurerm_virtual_machine_data_disk_attachment" "metadata" {
  count              = var.deployment_type != "active-active" ? var.metadata_disk_count : 0
  managed_disk_id    = azurerm_managed_disk.metadata[count.index].id
  virtual_machine_id = azurerm_linux_virtual_machine.mayanas[0].id  # Primary node for single/active-passive
  lun                = count.index
  caching            = "ReadOnly"
}

# RBAC Role Assignments for Managed Identity
# Network Contributor role for VIP management
resource "azurerm_role_assignment" "network_contributor" {
  count                = local.node_count
  scope                = local.resource_group.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_linux_virtual_machine.mayanas[count.index].identity[0].principal_id
}

# Reader role for resource discovery
resource "azurerm_role_assignment" "reader" {
  count                = local.node_count
  scope                = local.resource_group.id
  role_definition_name = "Reader"
  principal_id         = azurerm_linux_virtual_machine.mayanas[count.index].identity[0].principal_id
}

# Storage Blob Data Contributor role for storage access
resource "azurerm_role_assignment" "storage_contributor" {
  count                = local.node_count
  scope                = azurerm_storage_account.mayanas.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_virtual_machine.mayanas[count.index].identity[0].principal_id
}

# Subscription-level Reader role for managed identity authentication
resource "azurerm_role_assignment" "subscription_reader" {
  count                = local.node_count
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_linux_virtual_machine.mayanas[count.index].identity[0].principal_id
}

# Virtual Machine Contributor role for disk attach/detach operations
resource "azurerm_role_assignment" "vm_contributor" {
  count                = local.node_count
  scope                = local.resource_group.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_linux_virtual_machine.mayanas[count.index].identity[0].principal_id
}
