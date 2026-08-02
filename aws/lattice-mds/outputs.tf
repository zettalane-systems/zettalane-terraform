# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# AWS Lattice pNFS MDS - Outputs

output "mds_public_ip" {
  description = "MDS public IP address"
  value       = aws_instance.mds.public_ip
}

output "mds_private_ip" {
  description = "MDS private IP address (clients mount pNFS at this IP)"
  value       = aws_instance.mds.private_ip
}

output "mds_name" {
  description = "MDS instance name"
  value       = var.mds_name
}

output "ssh_user" {
  description = "SSH username for the MDS instance"
  value       = var.admin_username
}

output "ssh_command" {
  description = "SSH command to connect to the MDS"
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem ${var.admin_username}@${aws_instance.mds.public_ip}"
}

output "ami_id" {
  description = "AMI the MDS booted from"
  value       = local.ami_id
}
