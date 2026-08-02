# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Azure Lattice pNFS MDS - Outputs

output "mds_public_ip" {
  description = "MDS public IP address"
  value       = azurerm_public_ip.mds.ip_address
}

output "mds_private_ip" {
  description = "MDS private IP address (clients mount pNFS at this IP)"
  value       = azurerm_network_interface.mds.private_ip_address
}

output "mds_name" {
  description = "MDS VM name"
  value       = azurerm_linux_virtual_machine.mds.name
}

output "ssh_user" {
  description = "SSH username for the MDS VM"
  value       = var.admin_username
}

output "ssh_command" {
  description = "SSH command to connect to the MDS"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.mds.ip_address}"
}
