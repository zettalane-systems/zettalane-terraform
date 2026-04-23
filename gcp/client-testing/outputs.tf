# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# GCP Client Testing - Outputs

output "client_public_ip" {
  description = "Client public IP address"
  value       = google_compute_instance.client.network_interface[0].access_config[0].nat_ip
}

output "client_private_ip" {
  description = "Client private IP address"
  value       = google_compute_instance.client.network_interface[0].network_ip
}

output "client_name" {
  description = "Client instance name"
  value       = google_compute_instance.client.name
}

output "ssh_command" {
  description = "SSH command to connect to client"
  value       = "gcloud compute ssh ${var.admin_username}@${google_compute_instance.client.name} --zone=${var.zone} --project=${var.project_id}"
}

output "ssh_user" {
  description = "SSH username for client"
  value       = var.admin_username
}
