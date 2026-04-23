# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Cluster Information
output "cluster_name" {
  description = "Name of the MayaNAS cluster"
  value       = var.cluster_name
}

output "cluster_id" {
  description = "Unique cluster identifier"
  value       = random_id.suffix.hex
}

# Security Information
output "mayanas_password" {
  description = "Generated password for MayaNAS Web UI (Login: admin, URL: http://instance-ip:2020/). For SSH access use: ssh mayanas@instance-ip"
  value       = random_password.mayanas_password.result
  sensitive   = true
}

output "password_metadata_url" {
  description = "Command to retrieve Web UI password from instance metadata"
  value       = "curl -H \"Metadata-Flavor: Google\" http://metadata.google.internal/computeMetadata/v1/instance/attributes/mayanas-cloud_user_password"
}

# Standard outputs (consistent across all clouds)
output "node1_public_ip" {
  description = "Public IP of node 1"
  value       = var.assign_public_ip ? google_compute_instance.mayanas_node1.network_interface[0].access_config[0].nat_ip : null
}

output "node1_private_ip" {
  description = "Private IP of node 1"
  value       = google_compute_instance.mayanas_node1.network_interface[0].network_ip
}

output "node1_name" {
  description = "Name of node 1"
  value       = google_compute_instance.mayanas_node1.name
}

output "node2_public_ip" {
  description = "Public IP of node 2 (HA only)"
  value       = length(google_compute_instance.mayanas_node2) > 0 && var.assign_public_ip ? google_compute_instance.mayanas_node2[0].network_interface[0].access_config[0].nat_ip : null
}

output "node2_private_ip" {
  description = "Private IP of node 2 (HA only)"
  value       = length(google_compute_instance.mayanas_node2) > 0 ? google_compute_instance.mayanas_node2[0].network_interface[0].network_ip : null
}

output "node2_name" {
  description = "Name of node 2 (HA only)"
  value       = length(google_compute_instance.mayanas_node2) > 0 ? google_compute_instance.mayanas_node2[0].name : null
}

output "vip_address" {
  description = "Virtual IP address"
  value       = var.deployment_type != "single" ? local.vip_node1_address : null
}

output "vip_address_2" {
  description = "Second VIP (active-active only)"
  value       = var.deployment_type == "active-active" ? local.vip_node2_address : null
}

# NFS test paths for validation scripts
output "nfs_test_shares" {
  description = "NFS share paths for automated testing"
  value = var.deployment_type == "active-active" ? [
    "${local.vip_node1_address}:/${var.cluster_name}-pool-node1/${length(var.shares) > 0 ? var.shares[0].name : "share1"}",
    "${local.vip_node2_address}:/${var.cluster_name}-pool-node2/${length(var.shares) > 0 ? var.shares[0].name : "share1"}"
  ] : [
    "${var.deployment_type == "single" ? google_compute_instance.mayanas_node1.network_interface[0].network_ip : local.vip_node1_address}:/${var.cluster_name}-pool/${length(var.shares) > 0 ? var.shares[0].name : "share1"}"
  ]
}

output "alias_ip_range" {
  description = "Alias IP range for VIP"
  value       = local.vip_cidr_range
}

# Storage Information
output "gcs_bucket_names" {
  description = "Names of the GCS buckets for data storage"
  value       = [for bucket in google_storage_bucket.mayanas_data : bucket.name]
}

output "gcs_bucket_urls" {
  description = "URLs of the GCS buckets"
  value       = [for bucket in google_storage_bucket.mayanas_data : bucket.url]
}

output "total_bucket_count" {
  description = "Total number of GCS buckets created"
  value       = local.total_bucket_count
}

output "metadata_disk_names" {
  description = "Names of the metadata disks"
  value       = local.metadata_disk_names
}

output "total_metadata_disk_count" {
  description = "Total number of metadata disks created"
  value       = local.total_metadata_disk_count
}

output "metadata_disk_size_gb" {
  description = "Size of each metadata disk in GB"
  value       = var.metadata_disk_size_gb
}

# Service Account Information
output "service_account_email" {
  description = "Email of the MayaNAS service account"
  value       = google_service_account.mayanas_sa.email
}

# SSH Connection Information  
output "ssh_command_node1" {
  description = "SSH command to connect to Node 1"
  value       = "gcloud compute ssh mayanas@${google_compute_instance.mayanas_node1.name} --zone=${google_compute_instance.mayanas_node1.zone} --project=${var.project_id}"
}

output "ssh_command_node2" {
  description = "SSH command to connect to Node 2"
  value       = length(google_compute_instance.mayanas_node2) > 0 ? "gcloud compute ssh mayanas@${google_compute_instance.mayanas_node2[0].name} --zone=${google_compute_instance.mayanas_node2[0].zone} --project=${var.project_id}" : ""
}

# Web UI Access
output "web_ui_url_node1" {
  description = "URL for MayaNAS Web UI on Node 1 (via external IP)"
  value       = var.assign_public_ip ? "http://${google_compute_instance.mayanas_node1.network_interface[0].access_config[0].nat_ip}:2020/" : "Use SSH tunnel: gcloud compute ssh ... -- -L 2020:localhost:2020"
}

output "web_ui_url_node2" {
  description = "URL for MayaNAS Web UI on Node 2 (via external IP)"
  value       = length(google_compute_instance.mayanas_node2) > 0 && var.assign_public_ip ? "http://${google_compute_instance.mayanas_node2[0].network_interface[0].access_config[0].nat_ip}:2020/" : ""
}

# SSH Tunnel Commands for Web UI Access
output "ssh_tunnel_node1_web_ui" {
  description = "SSH tunnel command for Web UI access to Node 1 (then open http://localhost:2020)"
  value       = "gcloud compute ssh mayanas@${google_compute_instance.mayanas_node1.name} --zone=${google_compute_instance.mayanas_node1.zone} --project=${var.project_id} -- -L 2020:localhost:2020"
}

output "ssh_tunnel_node2_web_ui" {
  description = "SSH tunnel command for Web UI access to Node 2 (then open http://localhost:2021)"
  value       = length(google_compute_instance.mayanas_node2) > 0 ? "gcloud compute ssh mayanas@${google_compute_instance.mayanas_node2[0].name} --zone=${google_compute_instance.mayanas_node2[0].zone} --project=${var.project_id} -- -L 2021:localhost:2020" : ""
}

# Firewall Rules
output "firewall_ssh_rule" {
  description = "Name of the SSH firewall rule (IAP rule if enable_iap, else direct SSH rule)"
  value       = var.enable_iap ? google_compute_firewall.mayanas_iap_ssh[0].name : google_compute_firewall.mayanas_ssh[0].name
}

output "firewall_internal_rule" {
  description = "Name of the internal communication firewall rule"
  value       = google_compute_firewall.mayanas_internal.name
}

# Resource Tags
output "instance_tags" {
  description = "Tags applied to MayaNAS instances"
  value       = ["mayanas-${var.cluster_name}"]
}

# Share Mount Instructions
output "share_mount_instructions" {
  description = "Mount instructions for configured shares"
  value = {
    deployment_type = var.deployment_type
    shares = length(var.shares) > 0 ? (
      var.deployment_type == "active-active" ? {
        node1 = {
          for share in var.shares : share.name => {
            zpool       = "${var.cluster_name}-pool-node1"
            vip         = local.vip_node1_address
            nfs_mount   = contains(["nfs", "nfs3", "multi"], share.export) ? "mount -t nfs ${local.vip_node1_address}:/${var.cluster_name}-pool-node1/${share.name} /mnt/${share.name} (add -o vers=3 for NFSv3)" : ""
            smb_share   = contains(["smb", "multi"], share.export) ? "//${local.vip_node1_address}/${var.cluster_name}-pool-node1-${share.name}" : ""
            smb_user    = share.smb_user != "" ? share.smb_user : ""
          }
        }
        node2 = {
          for share in var.shares : share.name => {
            zpool       = "${var.cluster_name}-pool-node2"
            vip         = local.vip_node2_address
            nfs_mount   = contains(["nfs", "nfs3", "multi"], share.export) ? "mount -t nfs ${local.vip_node2_address}:/${var.cluster_name}-pool-node2/${share.name} /mnt/${share.name} (add -o vers=3 for NFSv3)" : ""
            smb_share   = contains(["smb", "multi"], share.export) ? "//${local.vip_node2_address}/${var.cluster_name}-pool-node2-${share.name}" : ""
            smb_user    = share.smb_user != "" ? share.smb_user : ""
          }
        }
      } : {
        node1 = {
          for share in var.shares : share.name => {
            zpool       = "${var.cluster_name}-pool"
            server_ip   = var.deployment_type == "single" ? google_compute_instance.mayanas_node1.network_interface[0].network_ip : local.vip_node1_address
            nfs_mount   = contains(["nfs", "nfs3", "multi"], share.export) ? "mount -t nfs ${var.deployment_type == "single" ? google_compute_instance.mayanas_node1.network_interface[0].network_ip : local.vip_node1_address}:/${var.cluster_name}-pool/${share.name} /mnt/${share.name} (add -o vers=3 for NFSv3)" : ""
            smb_share   = contains(["smb", "multi"], share.export) ? "//${var.deployment_type == "single" ? google_compute_instance.mayanas_node1.network_interface[0].network_ip : local.vip_node1_address}/${var.cluster_name}-pool-${share.name}" : ""
            smb_user    = share.smb_user != "" ? share.smb_user : ""
          }
        }
      }
    ) : {}
  }
}

# Deployment Info (structured, for automation/scripts)
output "deployment_info" {
  description = "Structured deployment information for automation"
  value = {
    cluster_name         = var.cluster_name
    deployment_type      = var.deployment_type
    machine_type         = var.machine_type
    total_bucket_count   = local.total_bucket_count
    node_count           = var.deployment_type == "single" ? 1 : 2
    region               = var.region
    node1_zone           = google_compute_instance.mayanas_node1.zone
    node2_zone           = length(google_compute_instance.mayanas_node2) > 0 ? google_compute_instance.mayanas_node2[0].zone : ""
    vip_address          = var.deployment_type != "single" ? local.vip_node1_address : ""
    vip_address_2        = var.deployment_type == "active-active" ? local.vip_node2_address : ""
    gcs_buckets          = [for bucket in google_storage_bucket.mayanas_data : bucket.name]
    metadata_disks       = local.metadata_disk_names
    metadata_disk_gb     = var.metadata_disk_size_gb
    source_image         = var.source_image
  }
}

# Deployment Summary (pretty text, for humans)
output "deployment_summary" {
  description = "Human-readable deployment summary"
  value = <<-EOT

    🎯 MayaNAS ${upper(var.deployment_type)} Deployment Complete!

    📋 CLUSTER INFORMATION
    ├─ Name: ${var.cluster_name}
    ├─ Type: ${upper(var.deployment_type)}
    ├─ Nodes: ${var.deployment_type == "single" ? 1 : 2}
    └─ Region: ${var.region}

    💻 INSTANCE DETAILS
    ├─ Machine Type: ${var.machine_type}
    ├─ Node1 Zone: ${google_compute_instance.mayanas_node1.zone}
    ${var.deployment_type != "single" ? "├─ Node2 Zone: ${length(google_compute_instance.mayanas_node2) > 0 ? google_compute_instance.mayanas_node2[0].zone : ""}" : ""}
    ├─ Node1 IP: ${google_compute_instance.mayanas_node1.network_interface[0].network_ip}${var.assign_public_ip ? " (${google_compute_instance.mayanas_node1.network_interface[0].access_config[0].nat_ip})" : " (no public IP)"}
    ${var.deployment_type != "single" && length(google_compute_instance.mayanas_node2) > 0 ? "└─ Node2 IP: ${google_compute_instance.mayanas_node2[0].network_interface[0].network_ip}${var.assign_public_ip ? " (${google_compute_instance.mayanas_node2[0].network_interface[0].access_config[0].nat_ip})" : " (no public IP)"}" : ""}

    🌐 NETWORK CONFIGURATION
    ├─ VPC: ${var.network_name}
    ${var.deployment_type != "single" ? "├─ VIP: ${local.vip_node1_address}" : ""}
    ${var.deployment_type == "active-active" ? "├─ VIP2: ${local.vip_node2_address}" : ""}
    └─ Subnet: ${var.subnet_name}

    💾 STORAGE CONFIGURATION
    ├─ GCS Buckets: ${local.total_bucket_count}
    ├─ Metadata Disks: ${length(local.metadata_disk_names)} x ${var.metadata_disk_size_gb}GB
    └─ Source Image: ${var.source_image}

    🔐 ACCESS METHODS
    ├─ SSH Node1: gcloud compute ssh mayanas@${google_compute_instance.mayanas_node1.name} --zone=${google_compute_instance.mayanas_node1.zone}
    ${var.deployment_type != "single" && length(google_compute_instance.mayanas_node2) > 0 ? "├─ SSH Node2: gcloud compute ssh mayanas@${google_compute_instance.mayanas_node2[0].name} --zone=${google_compute_instance.mayanas_node2[0].zone}" : ""}
    ├─ Web UI Tunnel: gcloud compute ssh mayanas@${google_compute_instance.mayanas_node1.name} --zone=${google_compute_instance.mayanas_node1.zone} -- -L 2020:localhost:2020
    └─ Web UI Access: http://localhost:2020 (after tunnel is active)

    📝 NEXT STEPS
    1. Wait 5-10 minutes for initial setup to complete
    2. Create SSH tunnel using command above
    3. Access Web UI at http://localhost:2020
    4. Configure file shares and user access

    🔧 TROUBLESHOOTING
    - Check startup logs: tail -f /opt/mayastor/logs/mayanas-terraform-startup.log
    - Service status: systemctl status mayastor
    ${var.deployment_type != "single" ? "- Cluster status: mayacli show failover" : ""}

    EOT
}

# Lustre Protocol Information
output "lustre_mount_command" {
  description = "Command to mount Lustre filesystem from client"
  value       = var.enable_lustre ? "mount -t lustre ${var.deployment_type == "single" ? google_compute_instance.mayanas_node1.network_interface[0].network_ip : local.vip_node1_address}@tcp:/${var.fsname} /mnt/lustre" : null
}

output "lustre_fsname" {
  description = "Lustre filesystem name"
  value       = var.enable_lustre ? var.fsname : null
}

output "lustre_mgs_nid" {
  description = "Lustre MGS NID (VIP for HA, internal IP for single node)"
  value       = var.enable_lustre ? "${var.deployment_type == "single" ? google_compute_instance.mayanas_node1.network_interface[0].network_ip : local.vip_node1_address}@tcp" : null
}
