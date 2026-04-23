# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Azure Client Testing - Outputs

output "client_public_ip" {
  description = "Client public IP address"
  value       = azurerm_public_ip.client.ip_address
}

output "client_private_ip" {
  description = "Client private IP address"
  value       = azurerm_network_interface.client.ip_configuration[0].private_ip_address
}

output "client_name" {
  description = "Client instance name"
  value       = azurerm_linux_virtual_machine.client.name
}

output "ssh_command" {
  description = "SSH command to connect to client"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.client.ip_address}"
}

output "ssh_user" {
  description = "SSH username for client"
  value       = var.admin_username
}
