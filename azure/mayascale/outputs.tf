# Azure MayaScale Terraform Outputs

# ============================================================================
# CLUSTER INFORMATION
# ============================================================================

output "cluster_name" {
  description = "MayaScale cluster name"
  value       = var.cluster_name
}

output "resource_group_name" {
  description = "Azure resource group name"
  value       = local.resource_group_name
}

output "location" {
  description = "Azure region"
  value       = local.resource_group.location
}

# ============================================================================
# PERFORMANCE TIER
# ============================================================================

output "performance_tier" {
  description = "Selected performance tier configuration"
  value = {
    tier                = var.performance_policy
    vm_size             = local.vm_size
    network_gbps        = local.selected_tier.network_gbps
    nvme_capacity_tb    = local.selected_tier.nvme_capacity_tb
    nvme_devices        = local.selected_tier.nvme_devices
    expected_read_iops  = local.selected_tier.target_read_iops
    expected_write_iops = local.selected_tier.target_write_iops
    expected_bw_mbps    = local.selected_tier.target_bw_mbps
    deployment_mode     = local.selected_tier.deployment_mode
    cost_per_node       = local.selected_tier.cost_per_month
    total_cost          = local.selected_tier.cost_per_month * var.node_count
  }
}

# ============================================================================
# NODE INFORMATION
# ============================================================================

output "nodes" {
  description = "List of all storage nodes with details"
  value = [
    for i in range(var.node_count) : {
      name        = azurerm_linux_virtual_machine.mayascale[i].name
      external_ip = azurerm_public_ip.mayascale[i].ip_address
      internal_ip = azurerm_network_interface.mayascale[i].private_ip_address
      zone        = azurerm_linux_virtual_machine.mayascale[i].zone
      vm_size     = azurerm_linux_virtual_machine.mayascale[i].size
    }
  ]
}

output "primary_node" {
  description = "Primary storage node (node0) details"
  value = {
    name        = azurerm_linux_virtual_machine.mayascale[0].name
    external_ip = azurerm_public_ip.mayascale[0].ip_address
    internal_ip = azurerm_network_interface.mayascale[0].private_ip_address
    zone        = azurerm_linux_virtual_machine.mayascale[0].zone
  }
}

output "secondary_node" {
  description = "Secondary storage node (node1) details if exists"
  value = var.node_count > 1 ? {
    name        = azurerm_linux_virtual_machine.mayascale[1].name
    external_ip = azurerm_public_ip.mayascale[1].ip_address
    internal_ip = azurerm_network_interface.mayascale[1].private_ip_address
    zone        = azurerm_linux_virtual_machine.mayascale[1].zone
  } : null
}

# Flat outputs for script compatibility
output "node1_public_ip" {
  description = "Node1 public IP address"
  value       = azurerm_public_ip.mayascale[0].ip_address
}

output "node1_private_ip" {
  description = "Node1 private IP address"
  value       = azurerm_network_interface.mayascale[0].private_ip_address
}

output "node1_name" {
  description = "Node1 VM name"
  value       = azurerm_linux_virtual_machine.mayascale[0].name
}

output "node2_public_ip" {
  description = "Node2 public IP address"
  value       = var.node_count > 1 ? azurerm_public_ip.mayascale[1].ip_address : ""
}

output "node2_private_ip" {
  description = "Node2 private IP address"
  value       = var.node_count > 1 ? azurerm_network_interface.mayascale[1].private_ip_address : ""
}

output "node2_name" {
  description = "Node2 VM name"
  value       = var.node_count > 1 ? azurerm_linux_virtual_machine.mayascale[1].name : ""
}

output "vip1_address" {
  description = "Primary VIP address"
  value       = local.vip_address_final
}

output "vip2_address" {
  description = "Secondary VIP address"
  value       = local.vip_address_2_final
}

output "virtual_network_name" {
  description = "Virtual network name for client deployment"
  value       = local.vnet_name
}

output "subnet_name" {
  description = "Subnet name for client deployment"
  value       = local.subnet_name
}

# ============================================================================
# NETWORKING
# ============================================================================

output "vnet_name" {
  description = "Virtual network name"
  value       = local.vnet_name
}

output "subnet_id" {
  description = "Subnet ID"
  value       = local.subnet_id
}

output "nsg_id" {
  description = "Network security group ID"
  value       = azurerm_network_security_group.mayascale.id
}

# Network Configuration - CRITICAL FOR VALIDATE-MAYASCALE.SH
output "vip_addresses" {
  description = "Virtual IP addresses for client connections"
  value = {
    primary_vip   = local.vip_address_final
    secondary_vip = local.vip_address_2_final
    active_vips   = local.selected_tier.nvme_devices > 1 ? [local.vip_address_final, local.vip_address_2_final] : [local.vip_address_final]
  }
}


# ============================================================================
# SSH ACCESS
# ============================================================================

output "ssh_commands" {
  description = "SSH commands to connect to each node"
  value = {
    for i in range(var.node_count) :
    "node${i + 1}" => "ssh ${var.admin_username}@${azurerm_public_ip.mayascale[i].ip_address}"
  }
}

# ============================================================================
# CLUSTER CONFIGURATION
# ============================================================================

output "cluster_config" {
  description = "Cluster configuration summary"
  value = {
    node_count         = var.node_count
    replica_count      = var.replica_count
    placement_group    = local.enable_ppg_final  # Auto-enabled for zonal, auto-disabled for regional
    placement_group_id = local.enable_ppg_final ? azurerm_proximity_placement_group.mayascale[0].id : null
    spot_instances     = var.use_spot_instances
    accelerated_network = var.enable_accelerated_networking
  }
}

# ============================================================================
# ESTIMATED CLUSTER PERFORMANCE
# ============================================================================

output "estimated_performance" {
  description = "Estimated cluster performance (aggregate across all nodes)"
  value = {
    total_read_iops       = local.selected_tier.target_read_iops * var.node_count
    total_write_iops      = local.selected_tier.target_write_iops * var.node_count
    total_bandwidth_mbps  = local.selected_tier.target_bw_mbps * var.node_count
    total_bandwidth_gbps  = (local.selected_tier.target_bw_mbps * var.node_count) / 1000
    total_nvme_capacity_tb = local.selected_tier.nvme_capacity_tb * var.node_count
    usable_capacity_tb    = (local.selected_tier.nvme_capacity_tb * var.node_count) / var.replica_count
    deployment_mode       = local.selected_tier.deployment_mode
  }
}

# ============================================================================
# COST ESTIMATE
# ============================================================================

output "cost_estimate" {
  description = "Monthly cost estimate (spot pricing)"
  value = {
    per_node_monthly  = local.selected_tier.cost_per_month
    total_monthly     = local.selected_tier.cost_per_month * var.node_count
    total_annual      = local.selected_tier.cost_per_month * var.node_count * 12
    pricing_model     = var.use_spot_instances ? "Spot (66% discount)" : "On-Demand"
  }
}

# ============================================================================
# VALIDATION HELPER
# ============================================================================

output "validation_command" {
  description = "Command to run validation script"
  value       = "../../common/validate-mayascale.sh -c azure -r ${local.resource_group_name} -z ${var.location}"
}

# Client Volumes - CRITICAL FOR VALIDATE-MAYASCALE.SH
output "client_volumes" {
  description = "Client volume NQN endpoints for data access"
  value = var.client_exports_enabled ? {
    for i in range(local.selected_tier.nvme_devices) : "data-node-${i + 1}" => {
      # NQN format: mayascale-{cluster_id}-vol-data-node-{n}
      # Odd volumes (1,3,5) use resource_id, even volumes (2,4,6) use peer_resource_id
      nqn          = "nqn.2019-05.com.zettalane:mayascale-${(i + 1) % 2 == 1 ? random_integer.resource_id.result : random_integer.peer_resource_id.result}-vol-data-node-${i + 1}"
      port         = var.client_nvme_port + i
      vip_endpoint = "${i % 2 == 0 ? local.vip_address_final : local.vip_address_2_final}:${var.client_nvme_port + i}"
      vip_address  = i % 2 == 0 ? local.vip_address_final : local.vip_address_2_final
      size_gb      = local.selected_tier.nvme_devices > 1 ? 375 : local.selected_tier.nvme_capacity_tb * 1024
      protocol     = var.client_protocol
      cluster_id   = (i + 1) % 2 == 1 ? random_integer.resource_id.result : random_integer.peer_resource_id.result
    }
  } : {}
}

# ============================================================================
# STANDARDIZED OUTPUTS (FOR VALIDATE-MAYASCALE.SH COMPATIBILITY)
# Following TERRAFORM_OUTPUT_STANDARDIZATION.md schema
# ============================================================================

output "deployment_summary" {
  description = "Summary of deployed configuration (standardized across clouds)"
  value = {
    cloud_provider        = "azure"
    cluster_name          = var.cluster_name
    deployment_id         = local.resource_group_name
    performance_policy    = var.performance_policy
    availability_strategy = var.node_count > 1 ? "cross-zone" : "single-zone"

    instance_type         = local.vm_size
    vcpus                 = lookup({
      "Standard_L2as_v4"  = 2,
      "Standard_L4as_v4"  = 4,
      "Standard_L4aos_v4" = 4,
      "Standard_L8as_v4"  = 8,
      "Standard_L8aos_v4" = 8,
      "Standard_L8s_v3"   = 8,
      "Standard_L8s_v2"   = 8,
      "Standard_L16s_v3"  = 16,
      "Standard_L16s_v2"  = 16,
      "Standard_L24aos_v4" = 24,
      "Standard_L32s_v3"  = 32,
      "Standard_L32s_v2"  = 32,
      "Standard_L32aos_v4" = 32,
      "Standard_L64as_v4" = 64,
      "Standard_L64s_v3"  = 64,
      "Standard_L64s_v2"  = 64,
      "Standard_L80s_v3"  = 80,
      "Standard_L80s_v2"  = 80,
      "Standard_L96as_v4" = 96
    }, local.vm_size, 0)
    nvme_capacity_gb      = floor(local.selected_tier.nvme_capacity_tb * 1024)
    ssd_count             = local.selected_tier.nvme_devices

    target_write_iops     = local.selected_tier.target_write_iops
    target_read_iops      = local.selected_tier.target_read_iops
    target_write_latency_us = 1000
    target_bandwidth_mbps = local.selected_tier.target_bw_mbps

    zone_primary          = var.node_count > 0 ? azurerm_linux_virtual_machine.mayascale[0].zone : ""
    zone_secondary        = var.node_count > 1 ? azurerm_linux_virtual_machine.mayascale[1].zone : ""
    region                = local.resource_group.location

    cost_tier             = local.selected_tier.deployment_mode
    dual_nic_enabled      = true
  }
}

output "availability_zones" {
  description = "List of availability zones used by storage nodes"
  value       = [for node in azurerm_linux_virtual_machine.mayascale : node.zone if node.zone != null && node.zone != ""]
}

output "admin_username" {
  description = "SSH admin username for VMs"
  value       = var.admin_username
}

# ============================================================================
# DEPLOYMENT INFO - Structured information for automation scripts
# ============================================================================

output "deployment_info" {
  description = "Structured deployment information for automation scripts"
  value = {
    cluster_name        = var.cluster_name
    node_count          = var.node_count
    region              = local.resource_group.location
    availability_zones  = [for node in azurerm_linux_virtual_machine.mayascale : node.zone if node.zone != null && node.zone != ""]
    machine_type        = local.vm_size
    node1_name          = azurerm_linux_virtual_machine.mayascale[0].name
    node1_zone          = azurerm_linux_virtual_machine.mayascale[0].zone
    node1_external_ip   = azurerm_public_ip.mayascale[0].ip_address
    node1_internal_ip   = azurerm_network_interface.mayascale[0].private_ip_address
    node2_name          = var.node_count > 1 ? azurerm_linux_virtual_machine.mayascale[1].name : ""
    node2_zone          = var.node_count > 1 ? azurerm_linux_virtual_machine.mayascale[1].zone : ""
    node2_external_ip   = var.node_count > 1 ? azurerm_public_ip.mayascale[1].ip_address : ""
    node2_internal_ip   = var.node_count > 1 ? azurerm_network_interface.mayascale[1].private_ip_address : ""
    vip_primary         = local.vip_address_final
    vip_secondary       = local.vip_address_2_final
    total_nvme_count    = local.selected_tier.nvme_devices * var.node_count
    total_capacity_gb   = local.selected_tier.nvme_capacity_tb * 1000 * var.node_count
  }
}