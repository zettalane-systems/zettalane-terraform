# Azure MayaScale Terraform Configuration
# NVMeoF storage cluster with local ephemeral NVMe

# ============================================================================
# PROVIDER CONFIGURATION
# ============================================================================

provider "azurerm" {
  subscription_id = var.subscription_id
  resource_provider_registrations = "core"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

# ============================================================================
# RANDOM GENERATORS FOR UNIQUE NAMING
# ============================================================================

resource "random_id" "suffix" {
  byte_length = 4
}

resource "random_id" "deployment" {
  byte_length = 4
}

# Generate cluster resource IDs (used by MayaScale for cluster identification)
resource "random_integer" "resource_id" {
  min = 1
  max = 255
}

resource "random_integer" "peer_resource_id" {
  min = 1
  max = 255
}

# ============================================================================
# PERFORMANCE POLICY DEFINITIONS (SINGLE SOURCE OF TRUTH)
# ============================================================================

locals {
  # Performance policies with full names matching GCP/AWS pattern
  # All policies use Laosv4 family (best bandwidth & value)
  # Regional: Cross-zone HA, writes reduced by ~17% due to cross-zone latency
  # Zonal: Same-zone, lowest latency, higher write performance
  performance_policies = {
    "regional-basic-performance" = {
      target_write_iops = 46000    # 0.83× zonal (cross-zone RAID1 sync overhead)
      target_read_iops  = 137500   # Same as zonal (client reads from local node)
      target_write_latency_us = 2000
      target_bandwidth_mbps = 12500
      availability_strategy = "cross-zone"
      vm_size = "Standard_L2as_v4"
      nvme_capacity_tb = 0.48
      nvme_devices = 1
      network_gbps = 12.5
      vcpus = 2
      cost_per_month = 25
    }

    "zonal-basic-performance" = {
      target_write_iops = 55000
      target_read_iops  = 137500
      target_write_latency_us = 1000
      target_bandwidth_mbps = 12500
      availability_strategy = "same-zone"
      vm_size = "Standard_L2as_v4"
      nvme_capacity_tb = 0.48
      nvme_devices = 1
      network_gbps = 12.5
      vcpus = 2
      cost_per_month = 25
    }

    "regional-standard-performance" = {
      target_write_iops = 120000   # 0.83× zonal
      target_read_iops  = 360000
      target_write_latency_us = 2000
      target_bandwidth_mbps = 10000
      availability_strategy = "cross-zone"
      vm_size = "Standard_L4aos_v4"
      nvme_capacity_tb = 2.88
      nvme_devices = 3
      network_gbps = 10
      vcpus = 4
      cost_per_month = 45
    }

    "zonal-standard-performance" = {
      target_write_iops = 144000
      target_read_iops  = 360000
      target_write_latency_us = 1000
      target_bandwidth_mbps = 10000
      availability_strategy = "same-zone"
      vm_size = "Standard_L4aos_v4"
      nvme_capacity_tb = 2.88
      nvme_devices = 3
      network_gbps = 10
      vcpus = 4
      cost_per_month = 45
    }

    "regional-medium-performance" = {
      target_write_iops = 360000   # 0.83× zonal (432K × 0.83)
      target_read_iops  = 1080000  # Azure spec
      target_write_latency_us = 2000
      target_bandwidth_mbps = 18750
      availability_strategy = "cross-zone"
      vm_size = "Standard_L12aos_v4"
      nvme_capacity_tb = 8.64     # 9 × 960GB
      nvme_devices = 9
      network_gbps = 18.75
      vcpus = 12
      cost_per_month = 150
    }

    "zonal-medium-performance" = {
      target_write_iops = 432000   # Azure spec: 432K write IOPS
      target_read_iops  = 1080000  # Azure spec: 1.08M read IOPS
      target_write_latency_us = 1000
      target_bandwidth_mbps = 18750
      availability_strategy = "same-zone"
      vm_size = "Standard_L12aos_v4"
      nvme_capacity_tb = 8.64     # 9 × 960GB
      nvme_devices = 9
      network_gbps = 18.75
      vcpus = 12
      cost_per_month = 150
    }

    "regional-high-performance" = {
      target_write_iops = 720000   # 0.83× zonal
      target_read_iops  = 2160000
      target_write_latency_us = 2000
      target_bandwidth_mbps = 37500
      availability_strategy = "cross-zone"
      vm_size = "Standard_L24aos_v4"
      nvme_capacity_tb = 17.28
      nvme_devices = 9
      network_gbps = 37.5
      vcpus = 24
      cost_per_month = 300
    }

    "zonal-high-performance" = {
      target_write_iops = 864000
      target_read_iops  = 2160000
      target_write_latency_us = 1000
      target_bandwidth_mbps = 37500
      availability_strategy = "same-zone"
      vm_size = "Standard_L24aos_v4"
      nvme_capacity_tb = 17.28
      nvme_devices = 9
      network_gbps = 37.5
      vcpus = 24
      cost_per_month = 300
    }

    "regional-ultra-performance" = {
      target_write_iops = 960000   # 0.83× zonal
      target_read_iops  = 2880000
      target_write_latency_us = 2000
      target_bandwidth_mbps = 50000
      availability_strategy = "cross-zone"
      vm_size = "Standard_L32aos_v4"
      nvme_capacity_tb = 23.04
      nvme_devices = 12
      network_gbps = 50
      vcpus = 32
      cost_per_month = 400
    }

    "zonal-ultra-performance" = {
      target_write_iops = 1152000
      target_read_iops  = 2880000
      target_write_latency_us = 1000
      target_bandwidth_mbps = 50000
      availability_strategy = "same-zone"
      vm_size = "Standard_L32aos_v4"
      nvme_capacity_tb = 23.04
      nvme_devices = 12
      network_gbps = 50
      vcpus = 32
      cost_per_month = 400
    }
  }

  # Selected policy configuration
  selected_policy = local.performance_policies[var.performance_policy]

  # Automatically disable PPG for regional (cross-zone) policies
  # PPG is incompatible with cross-zone deployment
  enable_ppg_final = var.enable_proximity_placement_group && !startswith(var.performance_policy, "regional-")

  # Regions that do NOT support availability zones
  regions_without_zones = ["westus", "westus3", "eastus2euap", "centraluseuap"]
  region_supports_zones = !contains(local.regions_without_zones, local.resource_group.location)
}

# ============================================================================
# SSH KEY CONFIGURATION
# ============================================================================

data "azurerm_client_config" "current" {}

# Get SSH key from Key Vault if specified
data "azurerm_key_vault_secret" "ssh_key" {
  count        = var.ssh_key_vault_id != "" ? 1 : 0
  name         = basename(var.ssh_key_vault_id)
  key_vault_id = dirname(var.ssh_key_vault_id)
}

# Get SSH key from Azure SSH Public Key resource if specified
data "azurerm_ssh_public_key" "ssh_key" {
  count               = var.ssh_key_resource_id != "" ? 1 : 0
  name                = basename(var.ssh_key_resource_id)
  resource_group_name = split("/", var.ssh_key_resource_id)[4]
}

# Validation: Ensure exactly one SSH key method is specified
locals {
  ssh_methods_count = (
    (var.ssh_public_key != "" ? 1 : 0) +
    (var.ssh_key_vault_id != "" ? 1 : 0) +
    (var.ssh_key_resource_id != "" ? 1 : 0)
  )

  ssh_public_key_final = (
    var.ssh_public_key != "" ? var.ssh_public_key :
    var.ssh_key_vault_id != "" ? data.azurerm_key_vault_secret.ssh_key[0].value :
    var.ssh_key_resource_id != "" ? data.azurerm_ssh_public_key.ssh_key[0].public_key :
    ""
  )
}

resource "null_resource" "ssh_key_validation" {
  count = local.ssh_methods_count != 1 ? 1 : 0

  provisioner "local-exec" {
    command = "echo 'ERROR: Exactly one SSH key method must be specified' && exit 1"
  }
}

# ============================================================================
# RESOURCE GROUP
# ============================================================================

# Check if resource group exists
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
  # If resource_group_name is specified, use it (whether it exists or needs to be created)
  # If not specified, generate a random name
  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "rg-${var.cluster_name}-${random_id.suffix.hex}"

  # Check if we should use existing RG (only if specified name exists)
  use_existing_rg = var.resource_group_name != "" && length(data.external.resource_group_exists) > 0 && data.external.resource_group_exists[0].result.exists == "true"

  # Create new RG if: (1) no name specified OR (2) specified name doesn't exist
  create_new_rg   = !local.use_existing_rg
}

# Use existing resource group
data "azurerm_resource_group" "existing" {
  count = local.use_existing_rg ? 1 : 0
  name  = var.resource_group_name
}

# Create new resource group
resource "azurerm_resource_group" "mayascale" {
  count    = local.create_new_rg ? 1 : 0
  name     = local.resource_group_name
  location = var.location

  tags = merge(var.tags, {
    Product     = "MayaScale"
    Terraform   = "true"
    ClusterName = var.cluster_name
  })
}

locals {
  resource_group = local.use_existing_rg ? data.azurerm_resource_group.existing[0] : azurerm_resource_group.mayascale[0]
}

# ============================================================================
# NETWORKING - VNet and Subnet
# ============================================================================

# Use existing VNet if specified
data "azurerm_virtual_network" "selected" {
  count               = var.vnet_name != "" ? 1 : 0
  name                = var.vnet_name
  resource_group_name = local.resource_group_name
}

# Create new VNet if not specified
resource "azurerm_virtual_network" "mayascale" {
  count               = var.vnet_name == "" ? 1 : 0
  name                = "vnet-${var.cluster_name}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  address_space       = [var.vnet_cidr]

  tags = merge(var.tags, {
    Product = "MayaScale"
  })
}

# Use existing subnet if specified
data "azurerm_subnet" "selected" {
  count                = var.subnet_name != "" ? 1 : 0
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = local.resource_group_name
}

# Create new subnet if not specified
resource "azurerm_subnet" "mayascale" {
  count                = var.subnet_name == "" ? 1 : 0
  name                 = "subnet-${var.cluster_name}"
  resource_group_name  = local.resource_group_name
  virtual_network_name = var.vnet_name != "" ? var.vnet_name : azurerm_virtual_network.mayascale[0].name
  address_prefixes     = [var.subnet_cidr]
}

# Backend subnet for storage replication traffic (regional, spans all zones like GCP)
resource "azurerm_subnet" "mayascale_backend" {
  name                 = "subnet-${var.cluster_name}-backend"
  resource_group_name  = local.resource_group_name
  virtual_network_name = var.vnet_name != "" ? var.vnet_name : azurerm_virtual_network.mayascale[0].name
  address_prefixes     = [var.backend_subnet_cidr]
}

locals {
  vnet_name = var.vnet_name != "" ? var.vnet_name : azurerm_virtual_network.mayascale[0].name
  subnet_name = var.subnet_name != "" ? var.subnet_name : azurerm_subnet.mayascale[0].name
  subnet_id = var.subnet_name != "" ? data.azurerm_subnet.selected[0].id : azurerm_subnet.mayascale[0].id
  backend_subnet_id = azurerm_subnet.mayascale_backend.id

  # VIP address auto-generation
  # For custom-route: VIPs outside subnet range to avoid routing conflicts
  # For load-balancer: VIPs within subnet range for Azure LB frontend
  subnet_cidr_final = var.subnet_name != "" ? data.azurerm_subnet.selected[0].address_prefixes[0] : var.subnet_cidr
  subnet_parts = split(".", split("/", local.subnet_cidr_final)[0])

  # Generate VIP outside subnet by using different third octet
  # E.g., for 10.0.1.0/24 -> 10.0.100.x, for 192.168.1.0/24 -> 192.168.100.x
  vip_network_base = format("%s.%s.100", local.subnet_parts[0], local.subnet_parts[1])

  vip_address_final = var.vip_address != "" ? var.vip_address : (
    var.vip_mechanism == "custom-route" ?
      format("%s.%d", local.vip_network_base, 100 + (random_integer.resource_id.result % 155)) :
      cidrhost(local.subnet_cidr_final, 100)
  )
  vip_address_2_final = var.vip_address_2 != "" ? var.vip_address_2 : (
    var.vip_mechanism == "custom-route" ?
      format("%s.%d", local.vip_network_base, 101 + (random_integer.resource_id.result % 154)) :
      cidrhost(local.subnet_cidr_final, 101)
  )

  # Backend IPs for storage replication (10.0.2.10, 10.0.2.11, etc.)
  backend_node_ips = [
    for i in range(var.node_count) :
    cidrhost(var.backend_subnet_cidr, 10 + i)
  ]
}

# ============================================================================
# NETWORK SECURITY GROUPS
# ============================================================================

# Primary NSG for client traffic
resource "azurerm_network_security_group" "mayascale" {
  name                = "nsg-${var.cluster_name}-${random_id.suffix.hex}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name

  # SSH access
  security_rule {
    name                       = "SSH"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = length(var.allowed_ssh_cidrs) > 0 ? var.allowed_ssh_cidrs : ["0.0.0.0/0"]
    destination_address_prefix = "*"
  }

  # NVMeoF TCP (port 4420)
  security_rule {
    name                       = "NVMeoF-TCP"
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "4420"
    source_address_prefixes    = length(var.allowed_nvmeof_cidrs) > 0 ? var.allowed_nvmeof_cidrs : [var.subnet_cidr]
    destination_address_prefix = "*"
  }

  # NVMeoF Discovery (port 8009)
  security_rule {
    name                       = "NVMeoF-Discovery"
    priority                   = 1020
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8009"
    source_address_prefixes    = length(var.allowed_nvmeof_cidrs) > 0 ? var.allowed_nvmeof_cidrs : [var.subnet_cidr]
    destination_address_prefix = "*"
  }

  # Allow all outbound
  security_rule {
    name                       = "AllowAllOutbound"
    priority                   = 2000
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "0.0.0.0/0"
    destination_address_prefix = "*"
  }

  tags = merge(var.tags, {
    Product = "MayaScale"
  })
}

# Backend NSG for storage replication traffic
resource "azurerm_network_security_group" "mayascale_backend" {
  name                = "nsg-${var.cluster_name}-backend-${random_id.suffix.hex}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name

  # Allow all traffic within backend subnet (for storage replication)
  security_rule {
    name                       = "AllowBackendTraffic"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.backend_subnet_cidr
    destination_address_prefix = var.backend_subnet_cidr
  }

  # Allow all outbound
  security_rule {
    name                       = "AllowAllOutbound"
    priority                   = 2000
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "0.0.0.0/0"
    destination_address_prefix = "*"
  }

  tags = merge(var.tags, {
    Product = "MayaScale"
    Purpose = "Backend replication traffic"
  })
}

# ============================================================================
# ROUTE TABLE FOR VIP (custom-route mechanism)
# ============================================================================

# Route Table for Custom Route VIP mechanism
# Required for Azure to route traffic to VIP addresses
# Name must be "mayanas-route-table" - expected by failover.pl
resource "azurerm_route_table" "mayascale" {
  count                         = var.vip_mechanism == "custom-route" && var.node_count > 1 ? 1 : 0
  name                          = "mayanas-route-table"
  location                      = local.resource_group.location
  resource_group_name           = local.resource_group_name
  bgp_route_propagation_enabled = true

  tags = merge(var.tags, {
    Product = "MayaScale"
    Purpose = "VIP routing for high availability"
  })
}

# Associate route table with primary subnet
resource "azurerm_subnet_route_table_association" "mayascale" {
  count          = var.vip_mechanism == "custom-route" && var.node_count > 1 ? 1 : 0
  subnet_id      = local.subnet_id
  route_table_id = azurerm_route_table.mayascale[0].id
}

# ============================================================================
# PROXIMITY PLACEMENT GROUP (for ultra-low latency)
# ============================================================================

resource "azurerm_proximity_placement_group" "mayascale" {
  count               = local.enable_ppg_final ? 1 : 0
  name                = "ppg-${var.cluster_name}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name

  tags = merge(var.tags, {
    Product = "MayaScale"
    Purpose = "Ultra-low latency between storage nodes"
  })
}

# ============================================================================
# PUBLIC IP ADDRESSES
# ============================================================================

resource "azurerm_public_ip" "mayascale" {
  count               = var.node_count
  name                = "pip-${var.cluster_name}-node${count.index + 1}-${random_id.deployment.hex}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"

  # Distribute nodes across availability zones (disable zones if using PPG)
  zones = local.enable_ppg_final ? [] : [tostring(var.availability_zones[count.index % length(var.availability_zones)])]

  lifecycle {
    precondition {
      condition     = local.enable_ppg_final || local.region_supports_zones
      error_message = "Regional (cross-zone) policies require availability zones, but region '${local.resource_group.location}' does not support zones. Either use a zonal-* policy or deploy to a zone-enabled region (westus2, eastus, centralus, etc.)."
    }
  }

  tags = merge(var.tags, {
    Product = "MayaScale"
    Node    = "node${count.index + 1}"
  })
}

# ============================================================================
# NETWORK INTERFACES
# ============================================================================

resource "azurerm_network_interface" "mayascale" {
  count                          = var.node_count
  name                           = "nic-${var.cluster_name}-node${count.index + 1}-${random_id.deployment.hex}"
  location                       = local.resource_group.location
  resource_group_name            = local.resource_group_name
  accelerated_networking_enabled = var.enable_accelerated_networking

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.mayascale[count.index].id
  }

  tags = merge(var.tags, {
    Product = "MayaScale"
    Node    = "node${count.index + 1}"
  })
}

# Associate NSG with network interfaces
resource "azurerm_network_interface_security_group_association" "mayascale" {
  count                     = var.node_count
  network_interface_id      = azurerm_network_interface.mayascale[count.index].id
  network_security_group_id = azurerm_network_security_group.mayascale.id
}

# Backend network interfaces for storage replication traffic
resource "azurerm_network_interface" "mayascale_backend" {
  count                          = var.node_count
  name                           = "nic-${var.cluster_name}-node${count.index + 1}-backend-${random_id.deployment.hex}"
  location                       = local.resource_group.location
  resource_group_name            = local.resource_group_name
  accelerated_networking_enabled = var.enable_accelerated_networking

  ip_configuration {
    name                          = "backend"
    subnet_id                     = local.backend_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.backend_node_ips[count.index]
  }

  tags = merge(var.tags, {
    Product = "MayaScale"
    Node    = "node${count.index + 1}"
    Purpose = "Backend replication"
  })
}

# Associate backend NSG with backend network interfaces
resource "azurerm_network_interface_security_group_association" "mayascale_backend" {
  count                     = var.node_count
  network_interface_id      = azurerm_network_interface.mayascale_backend[count.index].id
  network_security_group_id = azurerm_network_security_group.mayascale_backend.id
}

# ============================================================================
# STARTUP SCRIPT CONFIGURATION
# ============================================================================

locals {
  # NVMe device count per VM size (Azure L-series ephemeral NVMe)
  # Azure L-series have MULTIPLE physical NVMe devices (not one large device)
  nvme_count_map = {
    # Lasv4 family (AMD EPYC 9004) - varies by size
    "Standard_L2as_v4"  = 1   # 480 GB
    "Standard_L4as_v4"  = 2   # 960 GB (2 × 480GB)
    "Standard_L8as_v4"  = 4   # 1.92 TB (4 × 480GB)
    "Standard_L16as_v4" = 4   # 3.84 TB (4 × 960GB)
    "Standard_L32as_v4" = 8   # 7.68 TB (8 × 960GB)
    "Standard_L48as_v4" = 6   # 11.52 TB (6 × 1.92TB)
    "Standard_L64as_v4" = 8   # 15.36 TB (8 × 1.92TB)
    "Standard_L80as_v4" = 10  # 19.2 TB (10 × 1.92TB)
    "Standard_L96as_v4" = 12  # 23.04 TB (12 × 1.92TB)

    # Laosv4 family (AMD EPYC optimized storage) - MORE devices per vCPU!
    "Standard_L2aos_v4"  = 3  # 1.44 TB (3 × 480GB)
    "Standard_L4aos_v4"  = 3  # 2.88 TB (3 × 960GB)
    "Standard_L8aos_v4"  = 6  # 5.76 TB (6 × 960GB)
    "Standard_L12aos_v4" = 9  # 8.64 TB (9 × 960GB)
    "Standard_L16aos_v4" = 6  # 11.52 TB (6 × 1.92TB)
    "Standard_L24aos_v4" = 9  # 17.28 TB (9 × 1.92TB)
    "Standard_L32aos_v4" = 12 # 23.04 TB (12 × 1.92TB)

    # Lsv3 family (Intel Ice Lake) - 1 device per 8 vCPU
    "Standard_L8s_v3"  = 1    # 1.92 TB
    "Standard_L16s_v3" = 2    # 3.84 TB (2 × 1.92TB)
    "Standard_L32s_v3" = 4    # 7.68 TB (4 × 1.92TB)
    "Standard_L48s_v3" = 6    # 11.52 TB (6 × 1.92TB)
    "Standard_L64s_v3" = 8    # 15.36 TB (8 × 1.92TB)
    "Standard_L80s_v3" = 10   # 19.2 TB (10 × 1.92TB)

    # Lsv2 family (Intel Cascade Lake) - 1 device per 8 vCPU
    "Standard_L8s_v2"  = 1    # 1.92 TB
    "Standard_L16s_v2" = 2    # 3.84 TB (2 × 1.92TB)
    "Standard_L32s_v2" = 4    # 7.68 TB (4 × 1.92TB)
    "Standard_L48s_v2" = 6    # 11.52 TB (6 × 1.92TB)
    "Standard_L64s_v2" = 8    # 15.36 TB (8 × 1.92TB)
    "Standard_L80s_v2" = 10   # 19.2 TB (10 × 1.92TB)
  }
  nvme_count = lookup(local.nvme_count_map, local.vm_size, 1)

  startup_script = templatefile("${path.module}/startup-cluster.sh.tpl", {
    cluster_name         = var.cluster_name
    deployment_type      = var.deployment_type
    node_role           = "node1"  # Only node1 gets startup script
    node_count          = var.node_count
    replica_count       = var.replica_count
    location            = var.location
    resource_group      = local.resource_group_name
    performance_policy  = var.performance_policy
    vip_address         = local.vip_address_final
    vip_address_2       = local.vip_address_2_final
    resource_id         = random_integer.resource_id.result
    peer_resource_id    = random_integer.peer_resource_id.result
    secondary_private_ip = azurerm_network_interface.mayascale[1].ip_configuration[0].private_ip_address
    nvme_count          = local.nvme_count
    node1_name          = "${var.cluster_name}-node1-${random_id.deployment.hex}"
    node2_name          = var.node_count > 1 ? "${var.cluster_name}-node2-${random_id.deployment.hex}" : ""
    backend_node1_ip    = local.backend_node_ips[0]
    backend_node2_ip    = length(local.backend_node_ips) > 1 ? local.backend_node_ips[1] : ""
    client_nvme_port    = var.client_nvme_port
    client_iscsi_port   = var.client_iscsi_port
    client_protocol     = var.client_protocol
    client_exports_enabled = var.client_exports_enabled
    # Share configuration
    shares              = jsonencode(var.shares)
    # Startup wait configuration
    mayascale_startup_wait = var.mayascale_startup_wait != null ? tostring(var.mayascale_startup_wait) : ""
  })
}

# ============================================================================
# VIRTUAL MACHINES (Lasv5 with local NVMe)
# ============================================================================

resource "azurerm_linux_virtual_machine" "mayascale" {
  count               = var.node_count
  name                = "${var.cluster_name}-node${count.index + 1}-${random_id.deployment.hex}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  size                = local.vm_size

  # Availability zone (skip if using proximity placement group)
  zone = local.enable_ppg_final ? null : tostring(var.availability_zones[count.index % length(var.availability_zones)])

  # Proximity placement group for ultra-low latency
  proximity_placement_group_id = local.enable_ppg_final ? azurerm_proximity_placement_group.mayascale[0].id : null

  # Spot instance configuration
  priority        = var.use_spot_instances ? "Spot" : "Regular"
  eviction_policy = var.use_spot_instances ? "Deallocate" : null
  max_bid_price   = var.use_spot_instances ? var.spot_max_price : null

  disable_password_authentication = true

  # Two NICs: [0]=primary (client traffic), [1]=backend (replication)
  network_interface_ids           = [
    azurerm_network_interface.mayascale[count.index].id,
    azurerm_network_interface.mayascale_backend[count.index].id
  ]

  # OS Disk
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  # Image selection (custom or marketplace MayaScale)
  source_image_id = var.vm_image_id != "" ? var.vm_image_id : null

  # Azure Marketplace MayaScale image
  dynamic "source_image_reference" {
    for_each = var.vm_image_id == "" ? [1] : []
    content {
      publisher = "zettalane_systems-5254599"
      offer     = "mayascale-cloud-ent"
      sku       = "mayascale-cloud-ent"
      version   = "latest"
    }
  }

  # Marketplace plan (required for marketplace images)
  dynamic "plan" {
    for_each = var.vm_image_id == "" ? [1] : []
    content {
      name      = "mayascale-cloud-ent"
      publisher = "zettalane_systems-5254599"
      product   = "mayascale-cloud-ent"
    }
  }

  admin_username = var.admin_username

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_public_key_final
  }

  # System-assigned Managed Identity for Azure API access
  identity {
    type = "SystemAssigned"
  }

  # Security settings
  secure_boot_enabled = !var.disable_secure_boot
  vtpm_enabled        = !var.disable_vtpm

  # Startup script (only on node0 - it will configure the cluster)
  custom_data = count.index == 0 ? base64encode(local.startup_script) : null

  tags = merge(var.tags, {
    Product          = "MayaScale"
    Node             = "node${count.index + 1}"
    PerformanceTier  = var.performance_policy
    ClusterName      = var.cluster_name
  })

  depends_on = [
    azurerm_network_interface_security_group_association.mayascale,
    azurerm_network_interface_security_group_association.mayascale_backend
  ]
}

# ============================================================================
# RBAC ROLE ASSIGNMENTS
# ============================================================================

# Reader role for resource discovery
resource "azurerm_role_assignment" "reader" {
  count                = var.node_count
  scope                = local.resource_group.id
  role_definition_name = "Reader"
  principal_id         = azurerm_linux_virtual_machine.mayascale[count.index].identity[0].principal_id
}

# Network Contributor for VIP route table management
resource "azurerm_role_assignment" "network_contributor" {
  count                = var.node_count
  scope                = local.resource_group.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_linux_virtual_machine.mayascale[count.index].identity[0].principal_id
}

# Subscription-level Reader role for Azure API operations
resource "azurerm_role_assignment" "subscription_reader" {
  count                = var.node_count
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_linux_virtual_machine.mayascale[count.index].identity[0].principal_id
}

# Virtual Machine Contributor role for disk operations during failover
resource "azurerm_role_assignment" "vm_contributor" {
  count                = var.node_count
  scope                = local.resource_group.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_linux_virtual_machine.mayascale[count.index].identity[0].principal_id
}
