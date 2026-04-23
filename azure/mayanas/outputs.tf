# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Virtual Machine Information
output "vm_ids" {
  description = "IDs of the MayaNAS virtual machines"
  value       = azurerm_linux_virtual_machine.mayanas[*].id
}

output "vm_names" {
  description = "Names of the MayaNAS virtual machines"
  value       = azurerm_linux_virtual_machine.mayanas[*].name
}

output "private_ips" {
  description = "Private IP addresses of MayaNAS instances"
  value       = azurerm_network_interface.mayanas[*].ip_configuration[0].private_ip_address
}

output "public_ips" {
  description = "Public IP addresses of MayaNAS instances"
  value       = var.assign_public_ip ? azurerm_public_ip.mayanas[*].ip_address : []
}

# Standardized output names (for cross-cloud compatibility)
output "node1_name" {
  description = "Name of Node 1"
  value       = azurerm_linux_virtual_machine.mayanas[0].name
}

output "node2_name" {
  description = "Name of Node 2"
  value       = local.node_count > 1 ? azurerm_linux_virtual_machine.mayanas[1].name : null
}

output "node1_public_ip" {
  description = "Public IP of Node 1"
  value       = var.assign_public_ip ? azurerm_public_ip.mayanas[0].ip_address : null
}

output "node2_public_ip" {
  description = "Public IP of Node 2"
  value       = local.node_count > 1 && var.assign_public_ip ? azurerm_public_ip.mayanas[1].ip_address : null
}

output "node1_private_ip" {
  description = "Private IP of Node 1"
  value       = azurerm_network_interface.mayanas[0].ip_configuration[0].private_ip_address
}

output "node2_private_ip" {
  description = "Private IP of Node 2"
  value       = local.node_count > 1 ? azurerm_network_interface.mayanas[1].ip_configuration[0].private_ip_address : null
}

# SSH Connection Information
output "ssh_command_node1" {
  description = "SSH command for Node 1 (Primary)"
  value       = var.assign_public_ip ? "ssh -i ~/.ssh/${var.ssh_key_resource_id != "" ? basename(var.ssh_key_resource_id) : "id_rsa"}.pem azureuser@${azurerm_public_ip.mayanas[0].ip_address}" : "az ssh vm -n ${azurerm_linux_virtual_machine.mayanas[0].name} -g ${local.resource_group_name}"
}

output "ssh_command_node2" {
  description = "SSH command for Node 2 (Secondary) - HA deployments only"
  value       = local.node_count > 1 ? (var.assign_public_ip ? "ssh -i ~/.ssh/${var.ssh_key_resource_id != "" ? basename(var.ssh_key_resource_id) : "id_rsa"}.pem azureuser@${azurerm_public_ip.mayanas[1].ip_address}" : "az ssh vm -n ${azurerm_linux_virtual_machine.mayanas[1].name} -g ${local.resource_group_name}") : "N/A - Single node deployment"
}

# High Availability Information
output "vip_address" {
  description = "Virtual IP address for HA failover"
  value       = local.node_count > 1 ? local.vip_address_final : "N/A - Single node deployment"
}

output "vip_address_2" {
  description = "Second Virtual IP address (active-active only)"
  value       = var.deployment_type == "active-active" ? local.vip_address_2_final : "N/A - Not active-active deployment"
}

output "vip_mechanism" {
  description = "VIP mechanism being used"
  value       = local.node_count > 1 ? var.vip_mechanism : "N/A - Single node deployment"
}

output "load_balancer_ip" {
  description = "Load Balancer internal IP (when using load-balancer VIP mechanism)"
  value       = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? azurerm_lb.mayanas[0].frontend_ip_configuration[0].private_ip_address : "N/A"
}

output "load_balancer_public_ip" {
  description = "Load Balancer public IP (when using load-balancer VIP mechanism)"
  value       = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? azurerm_public_ip.lb[0].ip_address : "N/A"
}

# Storage Information
output "storage_account_name" {
  description = "Name of the Azure Storage Account"
  value       = azurerm_storage_account.mayanas.name
}

output "storage_account_id" {
  description = "ID of the Azure Storage Account"
  value       = azurerm_storage_account.mayanas.id
}

output "storage_containers" {
  description = "Names of the storage containers created"
  value       = azurerm_storage_container.mayanas[*].name
}

# Storage Credentials (for S3-compatible access)
output "storage_credentials" {
  description = "Storage credentials for S3-compatible access (key retrieved at runtime via managed identity)"
  sensitive   = true
  value = {
    storage_account = azurerm_storage_account.mayanas.name
    endpoint        = "https://${azurerm_storage_account.mayanas.name}.blob.core.windows.net"
    container       = azurerm_storage_container.mayanas[0].name
    auth_mode       = "managed_identity"
  }
}

output "metadata_disk_names" {
  description = "Names of the metadata disks"
  value       = azurerm_managed_disk.metadata[*].name
}

output "metadata_disk_sizes_gb" {
  description = "Sizes of metadata disks in GB"
  value       = azurerm_managed_disk.metadata[*].disk_size_gb
}

# Network Information
output "resource_group_name" {
  description = "Name of the resource group"
  value       = local.resource_group_name
}

output "virtual_network_name" {
  description = "Name of the virtual network"
  value       = local.virtual_network_name
}

output "subnet_id" {
  description = "ID of the subnet"
  value       = local.subnet_id
}

output "subnet_name" {
  description = "Name of the subnet"
  value       = var.subnet_name != "" ? var.subnet_name : azurerm_subnet.mayanas[0].name
}

output "network_security_group_id" {
  description = "ID of the network security group"
  value       = azurerm_network_security_group.mayanas.id
}

# Route Table Information (Custom Route VIP mechanism)
output "route_table_name" {
  description = "Name of the route table (custom-route VIP mechanism)"
  value       = var.vip_mechanism == "custom-route" && local.node_count > 1 ? azurerm_route_table.mayanas[0].name : "N/A"
}

output "route_table_id" {
  description = "ID of the route table (custom-route VIP mechanism)"
  value       = var.vip_mechanism == "custom-route" && local.node_count > 1 ? azurerm_route_table.mayanas[0].id : "N/A"
}

# Identity Information
output "managed_identity_principal_ids" {
  description = "Principal IDs of the system-assigned managed identities"
  value       = azurerm_linux_virtual_machine.mayanas[*].identity[0].principal_id
}

output "managed_identity_tenant_ids" {
  description = "Tenant IDs of the system-assigned managed identities"
  value       = azurerm_linux_virtual_machine.mayanas[*].identity[0].tenant_id
}

# Zone and Availability Information
output "availability_zones" {
  description = "Availability zones used for the deployment"
  value       = local.availability_zones
}

output "node_zones" {
  description = "Availability zones assigned to each node"
  value       = local.node_count > 1 ? [local.node1_zone, local.node2_zone] : [local.node1_zone]
}

# Deployment Info (structured, for automation/scripts)
output "deployment_info" {
  description = "Structured deployment information for automation"
  value = {
    cluster_name         = local.cluster_name
    deployment_type      = var.deployment_type
    machine_type         = var.vm_size
    total_bucket_count   = length(azurerm_storage_container.mayanas)
    node_count           = local.node_count
    region               = local.resource_group.location
    availability_zones   = local.availability_zones
    vip_mechanism        = local.node_count > 1 ? var.vip_mechanism : "N/A"
    vip_address          = local.node_count > 1 ? local.vip_address_final : "N/A"
    vip_address_2        = var.deployment_type == "active-active" ? local.vip_address_2_final : "N/A"
    storage_account      = azurerm_storage_account.mayanas.name
    storage_containers   = azurerm_storage_container.mayanas[*].name
    metadata_disk_count  = var.metadata_disk_count
    metadata_disk_gb     = var.metadata_disk_size_gb
    storage_size_gb      = var.storage_size_gb
  }
}

# Deployment Summary (pretty text, for humans)
output "deployment_summary" {
  description = "Human-readable deployment summary"
  value = <<-EOT

    🎯 MayaNAS ${upper(var.deployment_type)} Deployment Complete!

    📋 CLUSTER INFORMATION
    ├─ Name: ${local.cluster_name}
    ├─ Type: ${upper(var.deployment_type)}
    ├─ Nodes: ${local.node_count}
    └─ Environment: ${var.environment}

    💻 INSTANCE DETAILS
    ├─ VM Size: ${var.vm_size}
    ├─ Location: ${local.resource_group.location}
    ├─ Multi-Zone: ${var.multi_zone}
    ├─ Zones: ${join(", ", local.availability_zones)}
    └─ Accelerated Networking: ${var.enable_accelerated_networking}

    🌐 NETWORK CONFIGURATION
    ├─ Resource Group: ${local.resource_group_name}
    ├─ VNet: ${length(azurerm_virtual_network.mayanas) > 0 ? azurerm_virtual_network.mayanas[0].name : var.vnet_name}
    ├─ VIP Mechanism: ${local.node_count > 1 ? var.vip_mechanism : "N/A"}
    ${local.node_count > 1 ? "├─ VIP: ${local.vip_address_final}" : ""}
    ${var.deployment_type == "active-active" ? "├─ VIP2: ${local.vip_address_2_final}" : ""}
    └─ NSG: ${azurerm_network_security_group.mayanas.name}

    💾 STORAGE CONFIGURATION
    ├─ Storage Account: ${azurerm_storage_account.mayanas.name}
    ├─ Containers: ${length(azurerm_storage_container.mayanas)}
    ├─ Metadata Disks: ${var.metadata_disk_count} x ${var.metadata_disk_size_gb}GB
    ├─ Storage Capacity: ${var.storage_size_gb}GB (logical)
    └─ Performance Tier: ${var.performance_tier}

    🔐 ACCESS METHODS
    ├─ SSH Node1: az ssh vm -n ${azurerm_linux_virtual_machine.mayanas[0].name} -g ${local.resource_group_name}
    ${local.node_count > 1 ? "├─ SSH Node2: az ssh vm -n ${azurerm_linux_virtual_machine.mayanas[1].name} -g ${local.resource_group_name}" : ""}
    ├─ Web UI Tunnel: az ssh vm -n ${azurerm_linux_virtual_machine.mayanas[0].name} -g ${local.resource_group_name} -- -L 2020:localhost:2020
    └─ Web UI Access: http://localhost:2020 (after tunnel is active)

    📝 NEXT STEPS
    1. Wait 5-10 minutes for initial setup to complete
    2. Create SSH tunnel using command above
    3. Access Web UI at http://localhost:2020
    4. Configure file shares and user access

    🔧 TROUBLESHOOTING
    - Check startup logs: tail -f /opt/mayastor/logs/mayanas-terraform-startup.log
    - Service status: systemctl status mayastor
    - Cluster status: mayacli cluster status

    EOT
}

# NFS Mount Information
output "nfs_mount_commands" {
  description = "Commands to mount MayaNAS NFS shares"
  value = local.node_count > 1 ? [
    "# Mount from VIP (recommended for HA):",
    "sudo mount -t nfs ${local.vip_address_final}:/export /mnt/mayanas",
    "",
    "# Or mount directly from nodes:",
    "sudo mount -t nfs ${azurerm_network_interface.mayanas[0].ip_configuration[0].private_ip_address}:/export /mnt/mayanas",
    local.node_count > 1 ? "sudo mount -t nfs ${azurerm_network_interface.mayanas[1].ip_configuration[0].private_ip_address}:/export /mnt/mayanas" : ""
  ] : [
    "# Mount from single node:",
    "sudo mount -t nfs ${azurerm_network_interface.mayanas[0].ip_configuration[0].private_ip_address}:/export /mnt/mayanas"
  ]
}

# Management Commands
output "management_commands" {
  description = "Useful management commands for the deployment"
  value = {
    check_vm_status = "az vm list --resource-group ${local.resource_group_name} --output table"
    check_disk_status = "az disk list --resource-group ${local.resource_group_name} --output table"
    check_storage_account = "az storage account show --name ${azurerm_storage_account.mayanas.name} --resource-group ${local.resource_group_name}"
    check_load_balancer = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? "az lb show --name ${azurerm_lb.mayanas[0].name} --resource-group ${local.resource_group_name}" : "N/A"
    check_route_table = var.vip_mechanism == "custom-route" && local.node_count > 1 ? "az network route-table show --name ${azurerm_route_table.mayanas[0].name} --resource-group ${local.resource_group_name}" : "N/A"
    ssh_node1 = var.assign_public_ip ? "ssh -i ~/.ssh/${var.ssh_key_resource_id != "" ? basename(var.ssh_key_resource_id) : "id_rsa"}.pem azureuser@${azurerm_public_ip.mayanas[0].ip_address}" : "az ssh vm -n ${azurerm_linux_virtual_machine.mayanas[0].name} -g ${local.resource_group_name}"
    ssh_node2 = local.node_count > 1 ? (var.assign_public_ip ? "ssh -i ~/.ssh/${var.ssh_key_resource_id != "" ? basename(var.ssh_key_resource_id) : "id_rsa"}.pem azureuser@${azurerm_public_ip.mayanas[1].ip_address}" : "az ssh vm -n ${azurerm_linux_virtual_machine.mayanas[1].name} -g ${local.resource_group_name}") : "N/A"
  }
}

# Health Check Information
output "health_check_info" {
  description = "Health check and monitoring information"
  value = {
    health_probe_port = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? "61000" : "N/A"
    health_check_service = var.vip_mechanism == "load-balancer" && local.node_count > 1 ? "systemctl status mayanas-health-check" : "N/A"
    initialization_log = "/var/log/mayanas-init.log"
    mayanas_config = "/opt/mayastor/config/options"
    azure_storage_config = "/opt/mayastor/config/azure_storage"
  }
}

# Failover Information (for integration with existing MayaNAS logic)
output "failover_info" {
  description = "Information needed for MayaNAS failover.pl integration"
  value = {
    route_table_name = local.node_count > 1 && var.vip_mechanism == "custom-route" ? "mayanas-route-table" : ""
    route_vip1_name = local.node_count > 1 && var.vip_mechanism == "custom-route" ? "mayascale-route-vip1" : ""
    route_vip2_name = local.node_count > 1 && var.vip_mechanism == "custom-route" && var.deployment_type == "active-active" ? "mayascale-route-vip2" : ""
    lb_backend_pool = local.node_count > 1 && var.vip_mechanism == "load-balancer" ? azurerm_lb_backend_address_pool.mayanas[0].name : ""
    health_probe_port = local.node_count > 1 && var.vip_mechanism == "load-balancer" ? "61000" : ""
    resource_group = local.resource_group_name
    vip_addresses = local.node_count > 1 ? (var.deployment_type == "active-active" ? [local.vip_address_final, local.vip_address_2_final] : [local.vip_address_final]) : []
    message = local.node_count > 1 ? "" : "Single node deployment does not require failover configuration"
  }
}

# Share Mount Instructions (for validate-performance.sh compatibility)
output "share_mount_instructions" {
  description = "Mount instructions for configured shares"
  value = {
    deployment_type = var.deployment_type
    shares = length(var.shares) > 0 ? (
      var.deployment_type == "active-active" ? {
        node1 = {
          for share in var.shares : share.name => {
            zpool       = "${local.cluster_name}-pool-node1"
            vip         = local.vip_address_final
            nfs_mount   = contains(["nfs", "both"], share.export) ? "mount -t nfs ${local.vip_address_final}:/${local.cluster_name}-pool-node1/${share.name} /mnt/${share.name}" : ""
            smb_share   = contains(["smb", "both"], share.export) ? "//${local.vip_address_final}/${local.cluster_name}-pool-node1-${share.name}" : ""
          }
        }
        node2 = {
          for share in var.shares : share.name => {
            zpool       = "${local.cluster_name}-pool-node2"
            vip         = local.vip_address_2_final
            nfs_mount   = contains(["nfs", "both"], share.export) ? "mount -t nfs ${local.vip_address_2_final}:/${local.cluster_name}-pool-node2/${share.name} /mnt/${share.name}" : ""
            smb_share   = contains(["smb", "both"], share.export) ? "//${local.vip_address_2_final}/${local.cluster_name}-pool-node2-${share.name}" : ""
          }
        }
      } : {
        node1 = {
          for share in var.shares : share.name => {
            zpool       = "${local.cluster_name}-pool"
            server_ip   = var.deployment_type == "single" ? azurerm_network_interface.mayanas[0].ip_configuration[0].private_ip_address : local.vip_address_final
            nfs_mount   = contains(["nfs", "both"], share.export) ? "mount -t nfs ${var.deployment_type == "single" ? azurerm_network_interface.mayanas[0].ip_configuration[0].private_ip_address : local.vip_address_final}:/${local.cluster_name}-pool/${share.name} /mnt/${share.name}" : ""
            smb_share   = contains(["smb", "both"], share.export) ? "//${var.deployment_type == "single" ? azurerm_network_interface.mayanas[0].ip_configuration[0].private_ip_address : local.vip_address_final}/${local.cluster_name}-pool-${share.name}" : ""
          }
        }
      }
    ) : {}
  }
}

