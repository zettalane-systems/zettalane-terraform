# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Azure MayaScale Terraform Configuration
# NVMeoF storage cluster with local ephemeral NVMe

# ============================================================================
# PROVIDER CONFIGURATION
# ============================================================================

provider "azurerm" {
  subscription_id                 = var.subscription_id
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
      target_write_iops       = 46000  # 0.83× zonal (cross-zone RAID1 sync overhead)
      target_read_iops        = 137500 # Same as zonal (client reads from local node)
      target_write_latency_us = 2000
      target_bandwidth_mbps   = 12500
      availability_strategy   = "cross-zone"
      vm_size                 = "Standard_L2as_v4"
      nvme_capacity_tb        = 0.48
      nvme_devices            = 1
      network_gbps            = 12.5
      vcpus                   = 2
      cost_per_month          = 25
    }

    "zonal-basic-performance" = {
      target_write_iops       = 55000
      target_read_iops        = 137500
      target_write_latency_us = 1000
      target_bandwidth_mbps   = 12500
      availability_strategy   = "same-zone"
      vm_size                 = "Standard_L2as_v4"
      nvme_capacity_tb        = 0.48
      nvme_devices            = 1
      network_gbps            = 12.5
      vcpus                   = 2
      cost_per_month          = 25
    }

    "regional-standard-performance" = {
      target_write_iops       = 120000 # 0.83× zonal
      target_read_iops        = 360000
      target_write_latency_us = 2000
      target_bandwidth_mbps   = 10000
      availability_strategy   = "cross-zone"
      vm_size                 = "Standard_L4aos_v4"
      nvme_capacity_tb        = 2.88
      nvme_devices            = 3
      network_gbps            = 10
      vcpus                   = 4
      cost_per_month          = 45
    }

    "zonal-standard-performance" = {
      target_write_iops       = 144000
      target_read_iops        = 360000
      target_write_latency_us = 1000
      target_bandwidth_mbps   = 10000
      availability_strategy   = "same-zone"
      vm_size                 = "Standard_L4aos_v4"
      nvme_capacity_tb        = 2.88
      nvme_devices            = 3
      network_gbps            = 10
      vcpus                   = 4
      cost_per_month          = 45
    }

    "regional-medium-performance" = {
      target_write_iops       = 360000  # 0.83× zonal (432K × 0.83)
      target_read_iops        = 1080000 # Azure spec
      target_write_latency_us = 2000
      target_bandwidth_mbps   = 18750
      availability_strategy   = "cross-zone"
      vm_size                 = "Standard_L12aos_v4"
      nvme_capacity_tb        = 8.64 # 9 × 960GB
      nvme_devices            = 9
      network_gbps            = 18.75
      vcpus                   = 12
      cost_per_month          = 150
    }

    "zonal-medium-performance" = {
      target_write_iops       = 432000  # Azure spec: 432K write IOPS
      target_read_iops        = 1080000 # Azure spec: 1.08M read IOPS
      target_write_latency_us = 1000
      target_bandwidth_mbps   = 18750
      availability_strategy   = "same-zone"
      vm_size                 = "Standard_L12aos_v4"
      nvme_capacity_tb        = 8.64 # 9 × 960GB
      nvme_devices            = 9
      network_gbps            = 18.75
      vcpus                   = 12
      cost_per_month          = 150
    }

    "regional-high-performance" = {
      target_write_iops       = 720000 # 0.83× zonal
      target_read_iops        = 2160000
      target_write_latency_us = 2000
      target_bandwidth_mbps   = 37500
      availability_strategy   = "cross-zone"
      vm_size                 = "Standard_L24aos_v4"
      nvme_capacity_tb        = 17.28
      nvme_devices            = 9
      network_gbps            = 37.5
      vcpus                   = 24
      cost_per_month          = 300
    }

    "zonal-high-performance" = {
      target_write_iops       = 864000
      target_read_iops        = 2160000
      target_write_latency_us = 1000
      target_bandwidth_mbps   = 37500
      availability_strategy   = "same-zone"
      vm_size                 = "Standard_L24aos_v4"
      nvme_capacity_tb        = 17.28
      nvme_devices            = 9
      network_gbps            = 37.5
      vcpus                   = 24
      cost_per_month          = 300
    }

    "regional-ultra-performance" = {
      target_write_iops       = 960000 # 0.83× zonal
      target_read_iops        = 2880000
      target_write_latency_us = 2000
      target_bandwidth_mbps   = 50000
      availability_strategy   = "cross-zone"
      vm_size                 = "Standard_L32aos_v4"
      nvme_capacity_tb        = 23.04
      nvme_devices            = 12
      network_gbps            = 50
      vcpus                   = 32
      cost_per_month          = 400
    }

    "zonal-ultra-performance" = {
      target_write_iops       = 1152000
      target_read_iops        = 2880000
      target_write_latency_us = 1000
      target_bandwidth_mbps   = 50000
      availability_strategy   = "same-zone"
      vm_size                 = "Standard_L32aos_v4"
      nvme_capacity_tb        = 23.04
      nvme_devices            = 12
      network_gbps            = 50
      vcpus                   = 32
      cost_per_month          = 400
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
    # destroy-safe placeholder: a real apply always selects one of the three key
    # methods above (null_resource.ssh_key_validation errors on zero), so this is
    # never applied -- it only keeps public_key non-empty so a destroy plan, which
    # still schema-validates the attribute, doesn't fail when tfvars is gone.
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAVOCOYD8u/ulsYz6XkwTNL1Yij71r8SrpVExiGVJIk mayascale-destroy-placeholder-never-applied"
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

# Check if resource group exists.
# Query the SAME subscription the azurerm provider targets (var.subscription_id), NOT
# az CLI's default subscription -- otherwise an RG that exists in the target sub is
# reported missing, terraform sets create_new_rg=true and the apply fails with
# "a resource with the ID .../resourceGroups/<rg> already exists".
locals {
  # If resource_group_name is specified, use it; else generate a unique per-cluster name.
  resource_group_name = var.resource_group_name != "" ? var.resource_group_name : "rg-${var.cluster_name}-${random_id.suffix.hex}"

  # A NAMED RG is treated as SHARED/pre-existing: referenced via `data`, NEVER owned or
  # deleted -- a per-cluster destroy must not delete a shared RG (it would wipe the other
  # clusters in it). The deploy wrapper runs `az group create` (idempotent) first, so it
  # always exists. NO name -> own a unique per-cluster RG (safe to delete on destroy).
  # (Dropped the old `az group exists` external-data check: it FAILED OPEN -- a transient
  #  az error returned exists=false, so terraform adopted + later deleted the shared RG.)
  use_existing_rg = var.resource_group_name != ""
  create_new_rg   = var.resource_group_name == ""
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

# ----------------------------------------------------------------------------
# Shared "fabric" network: every pair joins ONE common VNet (default "mayascale-vnet")
# and ONE common frontend subnet ("mayascale-subnet"), created by the first pair and
# reused by the rest (use-if-exists, like the resource group / route table). cluster_slot
# then partitions the VIPs + the per-pair backend subnet so pairs never collide. Set
# vnet_name / subnet_name to join a specific pre-existing (e.g. customer) network instead.
# ----------------------------------------------------------------------------
locals {
  target_vnet_name   = var.vnet_name != "" ? var.vnet_name : "mayascale-vnet"
  target_subnet_name = var.subnet_name != "" ? var.subnet_name : "mayascale-subnet"
}

data "external" "vnet_exists" {
  count = var.resource_group_name != "" ? 1 : 0
  program = ["bash", "-c", <<-EOF
    if [ "$(az network vnet show --subscription "${var.subscription_id}" --resource-group "${var.resource_group_name}" --name "${local.target_vnet_name}" --query name -o tsv 2>/dev/null)" = "${local.target_vnet_name}" ]; then
      echo '{"exists":"true"}'
    else
      echo '{"exists":"false"}'
    fi
  EOF
  ]
}

data "external" "subnet_exists" {
  count = var.resource_group_name != "" ? 1 : 0
  program = ["bash", "-c", <<-EOF
    if [ "$(az network vnet subnet show --subscription "${var.subscription_id}" --resource-group "${var.resource_group_name}" --vnet-name "${local.target_vnet_name}" --name "${local.target_subnet_name}" --query name -o tsv 2>/dev/null)" = "${local.target_subnet_name}" ]; then
      echo '{"exists":"true"}'
    else
      echo '{"exists":"false"}'
    fi
  EOF
  ]
}

locals {
  use_existing_vnet   = try(data.external.vnet_exists[0].result.exists, "false") == "true"
  create_new_vnet     = !local.use_existing_vnet
  use_existing_subnet = try(data.external.subnet_exists[0].result.exists, "false") == "true"
  create_new_subnet   = !local.use_existing_subnet
}

# Reuse the shared VNet if it already exists (an earlier pair or the customer created it)
data "azurerm_virtual_network" "selected" {
  count               = local.use_existing_vnet ? 1 : 0
  name                = local.target_vnet_name
  resource_group_name = local.resource_group_name
}

# Create the shared VNet only if it does not exist yet (first pair)
resource "azurerm_virtual_network" "mayascale" {
  count               = local.create_new_vnet ? 1 : 0
  name                = local.target_vnet_name
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  address_space       = [var.vnet_cidr]

  tags = merge(var.tags, {
    Product = "MayaScale"
  })
}

# Reuse the shared frontend subnet if it exists
data "azurerm_subnet" "selected" {
  count                = local.use_existing_subnet ? 1 : 0
  name                 = local.target_subnet_name
  virtual_network_name = local.target_vnet_name
  resource_group_name  = local.resource_group_name
}

# Create the shared frontend subnet only if it does not exist yet (first pair)
resource "azurerm_subnet" "mayascale" {
  count                = local.create_new_subnet ? 1 : 0
  name                 = local.target_subnet_name
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.use_existing_vnet ? data.azurerm_virtual_network.selected[0].name : azurerm_virtual_network.mayascale[0].name
  address_prefixes     = [var.subnet_cidr]
}

# Backend subnet is PER-PAIR (cluster-named, cluster_slot-offset CIDR) inside the shared VNet.
# depends_on serializes subnet ops on the shared VNet (Azure rejects concurrent subnet writes).
resource "azurerm_subnet" "mayascale_backend" {
  count                = local.node_count > 1 ? 1 : 0
  name                 = "subnet-${var.cluster_name}-backend"
  resource_group_name  = local.resource_group_name
  virtual_network_name = local.use_existing_vnet ? data.azurerm_virtual_network.selected[0].name : azurerm_virtual_network.mayascale[0].name
  address_prefixes     = [local.backend_subnet_cidr_final]
  depends_on           = [azurerm_subnet.mayascale]
}

locals {
  vnet_name   = local.use_existing_vnet ? data.azurerm_virtual_network.selected[0].name : azurerm_virtual_network.mayascale[0].name
  subnet_name = local.use_existing_subnet ? data.azurerm_subnet.selected[0].name : azurerm_subnet.mayascale[0].name
  subnet_id   = local.use_existing_subnet ? data.azurerm_subnet.selected[0].id : azurerm_subnet.mayascale[0].id
  # topology from deployment_type: *-single -> 1 node, else 2 (active-active). single-node
  # drops the whole replication backend (no subnet/NSG/NIC). Mirrors azure/mayanas.
  node_count        = endswith(var.deployment_type, "-single") ? 1 : 2
  backend_subnet_id = local.node_count > 1 ? azurerm_subnet.mayascale_backend[0].id : null
  # csi control endpoint: active-active uses the floating VIP; single-node has NO VIP
  # (nothing binds/routes it), so the driver must reach configd at node1's real private IP.
  csi_node1_vip = local.node_count > 1 ? local.vip_address_final : azurerm_network_interface.mayascale[0].private_ip_address

  # VIP address auto-generation
  # For custom-route: VIPs outside subnet range to avoid routing conflicts
  # For load-balancer: VIPs within subnet range for Azure LB frontend
  subnet_cidr_final = local.use_existing_subnet ? data.azurerm_subnet.selected[0].address_prefixes[0] : var.subnet_cidr
  subnet_parts      = split(".", split("/", local.subnet_cidr_final)[0])

  # Generate VIP outside subnet by using different third octet
  # E.g., for 10.0.1.0/24 -> 10.0.100.x, for 192.168.1.0/24 -> 192.168.100.x
  vip_network_base = format("%s.%s.100", local.subnet_parts[0], local.subnet_parts[1])

  # cluster_slot > 0: deterministic 2-contiguous-slot VIPs per pair (matches GCP); 0: random (standalone)
  vip_offset1 = var.cluster_slot > 0 ? (var.cluster_slot * 2 + 1) : (100 + (random_integer.resource_id.result % 155))
  vip_offset2 = var.cluster_slot > 0 ? (var.cluster_slot * 2 + 2) : (101 + (random_integer.resource_id.result % 154))

  vip_address_final = var.vip_address != "" ? var.vip_address : (
    var.vip_mechanism == "custom-route" ?
    format("%s.%d", local.vip_network_base, local.vip_offset1) :
    cidrhost(local.subnet_cidr_final, 100)
  )
  vip_address_2_final = var.vip_address_2 != "" ? var.vip_address_2 : (
    var.vip_mechanism == "custom-route" ?
    format("%s.%d", local.vip_network_base, local.vip_offset2) :
    cidrhost(local.subnet_cidr_final, 101)
  )

  # Backend subnet is per-pair inside the (possibly shared) VNet, offset by cluster_slot so each
  # pair's static .10/.11 stay isolated: pair 0 -> 10.0.2.0/24, pair 1 -> 10.0.3.0/24, ...
  # (backend is node1<->node2 replication only, never shared across pairs).
  backend_subnet_cidr_final = var.cluster_slot > 0 ? cidrsubnet(var.vnet_cidr, 8, 2 + var.cluster_slot) : var.backend_subnet_cidr

  # Backend IPs for storage replication (10.0.2.10, 10.0.2.11, etc.)
  backend_node_ips = [
    for i in range(local.node_count) :
    cidrhost(local.backend_subnet_cidr_final, 10 + i)
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
  count               = local.node_count > 1 ? 1 : 0
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
    source_address_prefix      = local.backend_subnet_cidr_final
    destination_address_prefix = local.backend_subnet_cidr_final
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
# Custom-route VIP HA needs a route table for the VIP range. Its name is FIXED
# ("mayanas-route-table"), so a second cluster deployed into a shared resource group
# collides on create. Reuse it if it already exists (created by another cluster in this
# RG), else create it -- same use-if-exists pattern as the resource group, subscription-
# scoped for the same reason. Per-VIP routes are added at runtime by cluster_mayascale.sh,
# so the table itself is just an empty container.
locals {
  rt_enabled      = var.vip_mechanism == "custom-route" && local.node_count > 1
  use_existing_rt = local.rt_enabled && try(data.external.route_table_exists[0].result.exists, "false") == "true"
  create_new_rt   = local.rt_enabled && !local.use_existing_rt
  route_table_id  = local.rt_enabled ? (local.use_existing_rt ? data.azurerm_route_table.existing[0].id : azurerm_route_table.mayascale[0].id) : null
}

data "external" "route_table_exists" {
  count = local.rt_enabled && var.resource_group_name != "" ? 1 : 0
  program = ["bash", "-c", <<-EOF
    if [ "$(az network route-table show --subscription "${var.subscription_id}" --resource-group "${var.resource_group_name}" --name "mayanas-route-table" --query name -o tsv 2>/dev/null)" = "mayanas-route-table" ]; then
      echo '{"exists":"true"}'
    else
      echo '{"exists":"false"}'
    fi
  EOF
  ]
}

# Reuse the route table if another cluster already created it in this shared RG
data "azurerm_route_table" "existing" {
  count               = local.use_existing_rt ? 1 : 0
  name                = "mayanas-route-table"
  resource_group_name = local.resource_group_name
}

# Create the route table only when it does not already exist
resource "azurerm_route_table" "mayascale" {
  count                         = local.create_new_rt ? 1 : 0
  name                          = "mayanas-route-table"
  location                      = local.resource_group.location
  resource_group_name           = local.resource_group_name
  bgp_route_propagation_enabled = true

  tags = merge(var.tags, {
    Product = "MayaScale"
    Purpose = "VIP routing for high availability"
  })
}

# Associate the route table with the shared frontend subnet. Only the pair that CREATES
# the shared subnet does this (create_new_subnet); pairs that REUSE it skip the association,
# since the subnet already carries it and re-associating would collide.
resource "azurerm_subnet_route_table_association" "mayascale" {
  count          = local.rt_enabled && local.create_new_subnet ? 1 : 0
  subnet_id      = local.subnet_id
  route_table_id = local.route_table_id
}

# The per-VIP routes in the shared mayanas-route-table are added at RUNTIME by failover.pl
# (cluster_mayascale.sh), so terraform never sees them. failover.pl only deletes them on a
# graceful AzureLB stop -- a `terraform destroy` (or a VM crash) hard-deletes the VMs and
# never runs that path, so the two VIP routes would orphan in the shared table (dead routes
# pile up against Azure's per-table limit, and a stale /32 misroutes if its next-hop IP is
# later reused). This module created the VIPs, so it owns their cleanup: delete this pair's
# two routes by name on destroy. The route name is "mayascale-route-vip-<clusterid>" where
# clusterid IS the resource_id this module assigns each node -- random_integer.resource_id
# for node1/VIP1 and peer_resource_id for node2/VIP2 (same ids as the outputs' cluster_id).
# Targeting by name leaves other pairs' routes (different ids) untouched; on_failure=continue
# so a missing route, or the creator-pair's table already being gone, never blocks destroy.
resource "null_resource" "vip_route_cleanup" {
  count = local.rt_enabled ? 1 : 0

  triggers = {
    subscription = var.subscription_id
    rg           = local.resource_group_name
    route_table  = "mayanas-route-table"
    route1       = "mayascale-route-vip-${random_integer.resource_id.result}"
    route2       = "mayascale-route-vip-${random_integer.peer_resource_id.result}"
  }

  # On destroy terraform reverses create order, so depending on the table means our routes
  # are removed before the table itself is (for the pair that created it).
  depends_on = [azurerm_route_table.mayascale]

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      # az is already required by this module's existence probes, but auth/CLI may be
      # absent in some teardown contexts -- skip cleanly rather than erroring (the runtime
      # delete-by-prefix in failover.pl is the fallback for any route left behind).
      command -v az >/dev/null 2>&1 || exit 0
      for rn in ${self.triggers.route1} ${self.triggers.route2}; do
        az network route-table route delete --subscription ${self.triggers.subscription} \
          -g ${self.triggers.rg} --route-table-name ${self.triggers.route_table} -n "$rn" >/dev/null 2>&1 || true
      done
    EOT
  }
}

# ============================================================================
# PROXIMITY PLACEMENT GROUP (for ultra-low latency)
# ============================================================================

# The PPG is created/owned by storage, but the client VM is ALSO placed in it
# (client-testing passes this PPG's id) and the client outlives a storage
# destroy. So Azure keeps the PPG (it still has the client as a member) when
# storage is destroyed, and a storage redeploy then collides on create. Reuse
# it if it already exists, else create it -- same use-if-exists pattern as the
# route table / resource group, subscription-scoped.
locals {
  # try() guards the [0] index: with PPG opt-in off, ppg_exists is count=0 and the
  # `length>0 &&` guard does NOT stop terraform evaluating the index on the empty tuple.
  use_existing_ppg = local.enable_ppg_final && try(data.external.ppg_exists[0].result.exists, "false") == "true"
  create_new_ppg   = local.enable_ppg_final && !local.use_existing_ppg
  ppg_id           = local.enable_ppg_final ? (local.use_existing_ppg ? data.azurerm_proximity_placement_group.existing[0].id : azurerm_proximity_placement_group.mayascale[0].id) : null
}

data "external" "ppg_exists" {
  count = local.enable_ppg_final && var.resource_group_name != "" ? 1 : 0
  program = ["bash", "-c", <<-EOF
    if [ "$(az ppg show --subscription "${var.subscription_id}" --resource-group "${var.resource_group_name}" --name "ppg-${var.cluster_name}" --query name -o tsv 2>/dev/null)" = "ppg-${var.cluster_name}" ]; then
      echo '{"exists":"true"}'
    else
      echo '{"exists":"false"}'
    fi
  EOF
  ]
}

# Reuse the PPG if it already exists (e.g. still held by the client VM after a storage destroy)
data "azurerm_proximity_placement_group" "existing" {
  count               = local.use_existing_ppg ? 1 : 0
  name                = "ppg-${var.cluster_name}"
  resource_group_name = local.resource_group_name
}

# Create the PPG only when it does not already exist
resource "azurerm_proximity_placement_group" "mayascale" {
  count               = local.create_new_ppg ? 1 : 0
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
  count               = var.assign_public_ip ? local.node_count : 0
  name                = "pip-${var.cluster_name}-node${count.index + 1}-${random_id.deployment.hex}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"

  # Zone-pin only when the region has zones AND we're not colocating via PPG;
  # a no-zones region (or PPG) places without a zone -- regional vs zonal is
  # the POLICY tier (regional-*), not whether PPG is on.
  zones = (local.enable_ppg_final || !local.region_supports_zones) ? [] : [tostring(var.availability_zones[count.index % length(var.availability_zones)])]

  lifecycle {
    precondition {
      # Only a REGIONAL (cross-zone) policy actually requires zones; a zonal-*
      # policy is fine in a no-zones region (it just places without a zone).
      condition     = local.region_supports_zones || !startswith(var.performance_policy, "regional-")
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
  count                          = local.node_count
  name                           = "nic-${var.cluster_name}-node${count.index + 1}-${random_id.deployment.hex}"
  location                       = local.resource_group.location
  resource_group_name            = local.resource_group_name
  accelerated_networking_enabled = var.enable_accelerated_networking

  ip_configuration {
    name                          = "internal"
    subnet_id                     = local.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.assign_public_ip ? azurerm_public_ip.mayascale[count.index].id : null
  }

  tags = merge(var.tags, {
    Product = "MayaScale"
    Node    = "node${count.index + 1}"
  })
}

# Associate NSG with network interfaces
resource "azurerm_network_interface_security_group_association" "mayascale" {
  count                     = local.node_count
  network_interface_id      = azurerm_network_interface.mayascale[count.index].id
  network_security_group_id = azurerm_network_security_group.mayascale.id
}

# Backend network interfaces for storage replication traffic
resource "azurerm_network_interface" "mayascale_backend" {
  count                          = local.node_count > 1 ? local.node_count : 0
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
  count                     = local.node_count > 1 ? local.node_count : 0
  network_interface_id      = azurerm_network_interface.mayascale_backend[count.index].id
  network_security_group_id = azurerm_network_security_group.mayascale_backend[0].id
}

# ============================================================================
# STARTUP SCRIPT CONFIGURATION
# ============================================================================

locals {
  # NVMe device count per VM size (Azure L-series ephemeral NVMe)
  # Azure L-series have MULTIPLE physical NVMe devices (not one large device)
  nvme_count_map = {
    # Lasv4 family (AMD EPYC 9004) - varies by size
    "Standard_L2as_v4"  = 1  # 480 GB
    "Standard_L4as_v4"  = 2  # 960 GB (2 × 480GB)
    "Standard_L8as_v4"  = 4  # 1.92 TB (4 × 480GB)
    "Standard_L16as_v4" = 4  # 3.84 TB (4 × 960GB)
    "Standard_L32as_v4" = 8  # 7.68 TB (8 × 960GB)
    "Standard_L48as_v4" = 6  # 11.52 TB (6 × 1.92TB)
    "Standard_L64as_v4" = 8  # 15.36 TB (8 × 1.92TB)
    "Standard_L80as_v4" = 10 # 19.2 TB (10 × 1.92TB)
    "Standard_L96as_v4" = 12 # 23.04 TB (12 × 1.92TB)

    # Laosv4 family (AMD EPYC optimized storage) - MORE devices per vCPU!
    "Standard_L2aos_v4"  = 3  # 1.44 TB (3 × 480GB)
    "Standard_L4aos_v4"  = 3  # 2.88 TB (3 × 960GB)
    "Standard_L8aos_v4"  = 6  # 5.76 TB (6 × 960GB)
    "Standard_L12aos_v4" = 9  # 8.64 TB (9 × 960GB)
    "Standard_L16aos_v4" = 6  # 11.52 TB (6 × 1.92TB)
    "Standard_L24aos_v4" = 9  # 17.28 TB (9 × 1.92TB)
    "Standard_L32aos_v4" = 12 # 23.04 TB (12 × 1.92TB)

    # Lsv3 family (Intel Ice Lake) - 1 device per 8 vCPU
    "Standard_L8s_v3"  = 1  # 1.92 TB
    "Standard_L16s_v3" = 2  # 3.84 TB (2 × 1.92TB)
    "Standard_L32s_v3" = 4  # 7.68 TB (4 × 1.92TB)
    "Standard_L48s_v3" = 6  # 11.52 TB (6 × 1.92TB)
    "Standard_L64s_v3" = 8  # 15.36 TB (8 × 1.92TB)
    "Standard_L80s_v3" = 10 # 19.2 TB (10 × 1.92TB)

    # Lsv2 family (Intel Cascade Lake) - 1 device per 8 vCPU
    "Standard_L8s_v2"  = 1  # 1.92 TB
    "Standard_L16s_v2" = 2  # 3.84 TB (2 × 1.92TB)
    "Standard_L32s_v2" = 4  # 7.68 TB (4 × 1.92TB)
    "Standard_L48s_v2" = 6  # 11.52 TB (6 × 1.92TB)
    "Standard_L64s_v2" = 8  # 15.36 TB (8 × 1.92TB)
    "Standard_L80s_v2" = 10 # 19.2 TB (10 × 1.92TB)
  }
  nvme_count = lookup(local.nvme_count_map, local.vm_size, 1)

  startup_script = templatefile("${path.module}/startup-cluster.sh.tpl", {
    cluster_name           = var.cluster_name
    deployment_type        = var.deployment_type
    node_role              = "node1" # Only node1 gets startup script
    node_count             = local.node_count
    replica_count          = var.replica_count
    location               = var.location
    resource_group         = local.resource_group_name
    performance_policy     = var.performance_policy
    vip_address            = local.vip_address_final
    vip_address_2          = local.vip_address_2_final
    resource_id            = random_integer.resource_id.result
    peer_resource_id       = random_integer.peer_resource_id.result
    secondary_private_ip   = local.node_count > 1 ? azurerm_network_interface.mayascale[1].ip_configuration[0].private_ip_address : ""
    nvme_count             = local.nvme_count
    node1_name             = "${var.cluster_name}-node1-${random_id.deployment.hex}"
    node2_name             = local.node_count > 1 ? "${var.cluster_name}-node2-${random_id.deployment.hex}" : ""
    backend_node1_ip       = local.backend_node_ips[0]
    backend_node2_ip       = length(local.backend_node_ips) > 1 ? local.backend_node_ips[1] : ""
    client_nvme_port       = var.client_nvme_port
    client_iscsi_port      = var.client_iscsi_port
    client_protocol        = var.client_protocol
    client_exports_enabled = var.client_exports_enabled
    ha_data                = var.ha_data ? 1 : 0
    # Object cold tier: empty when bucket_count = 0, so the startup skips it.
    # s3_access_key is the storage ACCOUNT NAME -- on Azure that IS the accessID;
    # the node fetches the secret at runtime with its managed identity, so the
    # key never enters terraform or the state file.
    s3_access_key = local.object_tier_enabled ? azurerm_storage_account.mayascale[0].name : ""
    bucket_node1  = local.object_tier_enabled ? join(" ", slice(azurerm_storage_container.mayascale[*].name, 0, var.bucket_count)) : ""
    bucket_node2  = local.object_tier_enabled ? join(" ", slice(azurerm_storage_container.mayascale[*].name, var.bucket_count, local.total_bucket_count)) : ""
    # Share configuration
    shares = jsonencode(var.shares)
    # Startup wait configuration
    mayascale_startup_wait = var.mayascale_startup_wait != null ? tostring(var.mayascale_startup_wait) : ""
  })
}

# ============================================================================
# VIRTUAL MACHINES (Lasv5 with local NVMe)
# ============================================================================

resource "azurerm_linux_virtual_machine" "mayascale" {
  count               = local.node_count
  name                = "${var.cluster_name}-node${count.index + 1}-${random_id.deployment.hex}"
  location            = local.resource_group.location
  resource_group_name = local.resource_group_name
  size                = local.vm_size

  # Availability zone: skip if colocating via PPG OR the region has no zones.
  zone = (local.enable_ppg_final || !local.region_supports_zones) ? null : tostring(var.availability_zones[count.index % length(var.availability_zones)])

  # Proximity placement group for ultra-low latency (created or reused)
  proximity_placement_group_id = local.ppg_id

  # Spot instance configuration
  priority        = var.use_spot_instances ? "Spot" : "Regular"
  eviction_policy = var.use_spot_instances ? "Deallocate" : null
  max_bid_price   = var.use_spot_instances ? var.spot_max_price : null

  disable_password_authentication = true

  # NICs: [0]=primary (client traffic); [1]=backend (replication) only when multi-node
  network_interface_ids = local.node_count > 1 ? [
    azurerm_network_interface.mayascale[count.index].id,
    azurerm_network_interface.mayascale_backend[count.index].id
    ] : [
    azurerm_network_interface.mayascale[count.index].id
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
    Product         = "MayaScale"
    Node            = "node${count.index + 1}"
    PerformanceTier = var.performance_policy
    ClusterName     = var.cluster_name
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
  count                = local.node_count
  scope                = local.resource_group.id
  role_definition_name = "Reader"
  principal_id         = azurerm_linux_virtual_machine.mayascale[count.index].identity[0].principal_id
}

# Network Contributor for VIP route table management
resource "azurerm_role_assignment" "network_contributor" {
  count                = local.node_count
  scope                = local.resource_group.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_linux_virtual_machine.mayascale[count.index].identity[0].principal_id
}

# Subscription-level Reader role for Azure API operations
resource "azurerm_role_assignment" "subscription_reader" {
  count                = local.node_count
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = azurerm_linux_virtual_machine.mayascale[count.index].identity[0].principal_id
}

# Virtual Machine Contributor role for disk operations during failover
resource "azurerm_role_assignment" "vm_contributor" {
  count                = local.node_count
  scope                = local.resource_group.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_linux_virtual_machine.mayascale[count.index].identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Object storage for the objbacker cold tier (tenant datasets)
#
# The hot tier is local NVMe (zvol -> nvmet); this is the cold side that hot
# datasets are replicated onto (zfs send). Buckets are PER NODE, mirroring the
# mayanas layout: the account holds bucket_count * 2 containers, the first
# bucket_count belong to node1 and the remainder to node2, so each node builds
# its own objbacker pool and neither depends on the peer's object namespace.
# bucket_count = 0 (default) creates nothing -- existing clusters are unchanged.
# ---------------------------------------------------------------------------
locals {
  object_tier_enabled = var.bucket_count > 0
  total_bucket_count  = var.bucket_count * 2

  # DNS-compliant: 3-24 chars, lowercase alnum only. cluster_name is <=15.
  storage_account_name = "st${replace(lower(var.cluster_name), "-", "")}${substr(random_id.deployment.hex, 0, 6)}"
}

resource "azurerm_storage_account" "mayascale" {
  count                    = local.object_tier_enabled ? 1 : 0
  name                     = local.storage_account_name
  resource_group_name      = local.resource_group_name
  location                 = local.resource_group.location
  account_tier             = split("_", var.storage_account_type)[0]
  account_replication_type = split("_", var.storage_account_type)[1]
  account_kind             = "StorageV2"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  tags = merge(var.tags, {
    Product     = "MayaScale"
    Terraform   = "true"
    ClusterName = var.cluster_name
  })
}

resource "azurerm_storage_container" "mayascale" {
  count                 = local.total_bucket_count
  name                  = "${var.cluster_name}-data-${count.index}-${random_id.deployment.hex}"
  storage_account_id    = azurerm_storage_account.mayascale[0].id
  container_access_type = "private"
}
