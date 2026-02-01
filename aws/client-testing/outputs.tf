# AWS Client Testing - Outputs

output "client_public_ip" {
  description = "Client public IP address"
  value       = aws_instance.client.public_ip
}

output "client_private_ip" {
  description = "Client private IP address"
  value       = aws_instance.client.private_ip
}

output "client_name" {
  description = "Client instance name"
  value       = aws_instance.client.tags["Name"]
}

output "ssh_command" {
  description = "SSH command to connect to client"
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem ${var.admin_username}@${aws_instance.client.public_ip}"
}

output "ssh_user" {
  description = "SSH username for client"
  value       = var.admin_username
}
