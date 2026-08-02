# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# GCP Lattice pNFS MDS - Outputs

output "mds_public_ip" {
  description = "MDS public IP address"
  value       = google_compute_instance.mds.network_interface[0].access_config[0].nat_ip
}

output "mds_private_ip" {
  description = "MDS private IP address (clients mount pNFS at this IP)"
  value       = google_compute_instance.mds.network_interface[0].network_ip
}

output "mds_name" {
  description = "MDS instance name"
  value       = google_compute_instance.mds.name
}

output "ssh_user" {
  description = "SSH username for the MDS VM"
  value       = var.admin_username
}

output "ssh_command" {
  description = "SSH command to connect to the MDS"
  value       = "gcloud compute ssh ${var.admin_username}@${google_compute_instance.mds.name} --zone=${var.zone} --project=${var.project_id}"
}
