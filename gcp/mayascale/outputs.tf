# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# MayaScale GCP Marketplace Outputs

# Cluster Information
output "cluster_name" {
  description = "Name of the MayaScale cluster"
  value       = local.cluster_name
}

output "deployment_summary" {
  description = "Summary of deployed configuration"
  value = {
    cluster_name          = local.cluster_name
    performance_policy    = var.performance_policy
    availability_strategy = local.active_policy.availability_strategy
    target_iops          = local.active_policy.target_write_iops
    instance_type        = local.selected_machine_type
    nvme_capacity_gb     = local.active_policy.local_ssd_count * 375 * 2  # Total across both nodes
    cost_tier           = local.active_policy.capacity_optimization
    zone_strategy       = local.zone_strategy
    dual_nic_enabled    = true
  }
}

# Node Information - Flat outputs for script compatibility
output "node1_public_ip" {
  description = "Public IP of node 1"
  value       = var.assign_public_ip ? google_compute_instance.mayascale_nodes[0].network_interface[0].access_config[0].nat_ip : null
}

output "node1_private_ip" {
  description = "Private IP of node 1"
  value       = google_compute_instance.mayascale_nodes[0].network_interface[0].network_ip
}

output "node1_name" {
  description = "Name of node 1"
  value       = google_compute_instance.mayascale_nodes[0].name
}

output "node2_public_ip" {
  description = "Public IP of node 2"
  value       = var.assign_public_ip ? google_compute_instance.mayascale_nodes[1].network_interface[0].access_config[0].nat_ip : null
}

output "node2_private_ip" {
  description = "Private IP of node 2"
  value       = google_compute_instance.mayascale_nodes[1].network_interface[0].network_ip
}

output "node2_name" {
  description = "Name of node 2"
  value       = google_compute_instance.mayascale_nodes[1].name
}

output "vip1_address" {
  description = "Primary VIP address"
  value       = local.vip_address
}

output "vip2_address" {
  description = "Secondary VIP address"
  value       = local.vip_address_2
}

# Node Information - Structured
output "primary_node" {
  description = "Primary MayaScale storage node information"
  value = {
    name        = google_compute_instance.mayascale_nodes[0].name
    zone        = google_compute_instance.mayascale_nodes[0].zone
    internal_ip = google_compute_instance.mayascale_nodes[0].network_interface[0].network_ip
    backend_ip  = google_compute_instance.mayascale_nodes[0].network_interface[1].network_ip
    external_ip = var.assign_public_ip ? google_compute_instance.mayascale_nodes[0].network_interface[0].access_config[0].nat_ip : null
    instance_id = google_compute_instance.mayascale_nodes[0].instance_id
  }
}

output "secondary_node" {
  description = "Secondary MayaScale storage node information"
  value = {
    name        = google_compute_instance.mayascale_nodes[1].name
    zone        = google_compute_instance.mayascale_nodes[1].zone
    internal_ip = google_compute_instance.mayascale_nodes[1].network_interface[0].network_ip
    backend_ip  = google_compute_instance.mayascale_nodes[1].network_interface[1].network_ip
    external_ip = var.assign_public_ip ? google_compute_instance.mayascale_nodes[1].network_interface[0].access_config[0].nat_ip : null
    instance_id = google_compute_instance.mayascale_nodes[1].instance_id
  }
}

# Network Configuration
output "vip_addresses" {
  description = "Virtual IP addresses for client connections"
  value = {
    primary_vip = local.vip_address
    secondary_vip = local.vip_address_2
    active_vips = local.active_policy.local_ssd_count > 1 ? [local.vip_address, local.vip_address_2] : [local.vip_address]
  }
}

# Backward compatibility
output "vip_address" {
  description = "Primary virtual IP address for client connections"
  value       = local.vip_address
}

output "client_volumes" {
  description = "Client volume NQN endpoints for data access"
  value = var.client_exports_enabled ? {
    for i in range(local.active_policy.local_ssd_count) : "data-node-${i + 1}" => {
      # NQN format: mayascale-{cluster_id}-vol-data-node-{n}
      # Odd volumes (1,3,5) use resource_id, even volumes (2,4,6) use peer_resource_id
      nqn  = "nqn.2019-05.com.zettalane:mayascale-${(i + 1) % 2 == 1 ? random_integer.resource_id.result : random_integer.peer_resource_id.result}-vol-data-node-${i + 1}"
      port = var.client_nvme_port + i
      vip_endpoint = "${i % 2 == 0 ? local.vip_address : local.vip_address_2}:${var.client_nvme_port + i}"
      vip_address = i % 2 == 0 ? local.vip_address : local.vip_address_2
      size_gb = 375  # Each Local SSD size
      protocol = var.client_protocol
      cluster_id = (i + 1) % 2 == 1 ? random_integer.resource_id.result : random_integer.peer_resource_id.result
    }
  } : {}
}

# Client discovery output - Discovery endpoints for nvme discover commands
output "client_discovery_info" {
  description = "NVMe-oF discovery endpoints for client connection"
  value = {
    enabled      = var.client_exports_enabled
    volume_count = var.client_exports_enabled ? local.active_policy.local_ssd_count : 0
    # Discovery endpoints - client runs: nvme discover -t tcp -a <vip> -s <port>
    discovery_endpoints = var.client_exports_enabled ? [
      {
        vip_address = local.vip_address
        port        = var.client_nvme_port
        cluster_id  = random_integer.resource_id.result
        nqn         = "nqn.2019-05.com.zettalane:mayascale-${random_integer.resource_id.result}-vol-data-node-1"
      },
      {
        vip_address = local.vip_address_2
        port        = var.client_nvme_port + 1
        cluster_id  = random_integer.peer_resource_id.result
        nqn         = "nqn.2019-05.com.zettalane:mayascale-${random_integer.peer_resource_id.result}-vol-data-node-2"
      }
    ] : []
  }
}

# Management URLs
output "management_urls" {
  description = "Management interface URLs"
  value = {
    primary_web_ui   = var.assign_public_ip ? "http://${google_compute_instance.mayascale_nodes[0].network_interface[0].access_config[0].nat_ip}:2020" : "Use SSH tunnel: gcloud compute ssh ... -- -L 2020:localhost:2020"
    secondary_web_ui = var.assign_public_ip ? "http://${google_compute_instance.mayascale_nodes[1].network_interface[0].access_config[0].nat_ip}:2020" : "Use SSH tunnel: gcloud compute ssh ... -- -L 2021:localhost:2020"
    cluster_metrics  = "http://${local.vip_address}:9090"
  }
}

# SSH Commands
output "ssh_commands" {
  description = "SSH commands to connect to nodes"
  value = {
    primary_node   = var.assign_public_ip ? "ssh mayascale@${google_compute_instance.mayascale_nodes[0].network_interface[0].access_config[0].nat_ip}" : "gcloud compute ssh mayascale@${google_compute_instance.mayascale_nodes[0].name} --zone=${google_compute_instance.mayascale_nodes[0].zone} --project=${var.project_id}"
    secondary_node = var.assign_public_ip ? "ssh mayascale@${google_compute_instance.mayascale_nodes[1].network_interface[0].access_config[0].nat_ip}" : "gcloud compute ssh mayascale@${google_compute_instance.mayascale_nodes[1].name} --zone=${google_compute_instance.mayascale_nodes[1].zone} --project=${var.project_id}"
  }
}

# Performance Characteristics
output "performance_characteristics" {
  description = "Actual performance characteristics of deployed infrastructure"
  value = {
    target_iops             = local.active_policy.target_write_iops
    target_read_iops        = local.active_policy.target_read_iops
    nvme_devices_per_node   = local.active_policy.local_ssd_count
    total_nvme_capacity_tb  = (local.active_policy.local_ssd_count * 375 * 2) / 1024  # Total TB
    instance_type           = local.selected_machine_type
    backend_network_enabled = true
    nvmeof_port            = 4420
    replication_port       = 8010
  }
}

# Kubernetes CSI Integration
output "kubernetes_csi_config" {
  description = "Configuration for Kubernetes CSI driver integration"
  value = {
    storage_class_name = "${local.cluster_name}-mayascale"
    csi_driver_name   = "mayascale.csi.storage.k8s.io"
    nvmeof_endpoints  = [
      "${google_compute_instance.mayascale_nodes[0].network_interface[0].network_ip}:4420",
      "${google_compute_instance.mayascale_nodes[1].network_interface[0].network_ip}:4420"
    ]
    vip_endpoint = "${local.vip_address}:4420"
    performance_class = local.active_policy.capacity_optimization
    target_iops = local.active_policy.target_write_iops
  }
}

# Network Architecture
output "network_architecture" {
  description = "Professional dual-NIC network configuration"
  value = {
    frontend_network = {
      name = "default"
      purpose = "Client NVMe-oF connections"
      port = 4420
      primary_ip = google_compute_instance.mayascale_nodes[0].network_interface[0].network_ip
      secondary_ip = google_compute_instance.mayascale_nodes[1].network_interface[0].network_ip
    }
    backend_network = {
      name = google_compute_network.mayascale_backend.name
      purpose = "Server-side replication traffic"
      port = 8010
      cidr = "10.200.0.0/24"
      primary_ip = google_compute_instance.mayascale_nodes[0].network_interface[1].network_ip
      secondary_ip = google_compute_instance.mayascale_nodes[1].network_interface[1].network_ip
    }
  }
}

# Service Account
output "service_account_email" {
  description = "Service account email for MayaScale operations"
  value       = google_service_account.mayascale_service_account.email
}

# Password Access
output "mayascale_password" {
  description = "Generated password for MayaScale Web UI (Login: admin, URL: http://instance-ip:2020/). For SSH access use: ssh mayascale@instance-ip"
  value       = nonsensitive(random_password.mayascale_password.result)
  sensitive   = false
}

output "password_metadata_url" {
  description = "Metadata URL to retrieve password from within instance"
  value       = "curl -H \"Metadata-Flavor: Google\" http://metadata.google.internal/computeMetadata/v1/instance/attributes/mayascale-cloud_user_password"
}

# Placement Policy (for client co-location)
output "placement_policy_name" {
  description = "Name of compact placement policy for co-locating test clients (only available for zonal deployments)"
  value = (
    local.active_policy.availability_strategy == "same-zone" ?
    (var.placement_policy_name != "" ?
      var.placement_policy_name :
      (length(google_compute_resource_policy.mayascale_placement_policy) > 0 ?
        google_compute_resource_policy.mayascale_placement_policy[0].name : "")) :
    ""
  )
}

output "placement_policy_id" {
  description = "Full resource ID of placement policy for client Terraform to reference (use in resource_policies)"
  value       = local.placement_policy_id
}

output "placement_zone" {
  description = "Zone where placement policy is active (client must be in same zone for co-location)"
  value       = local.active_policy.availability_strategy == "same-zone" ? var.zone : ""
}

output "placement_client_slots" {
  description = "Number of client VM slots reserved in placement policy (0 = storage-only, >0 = deploy client concurrently)"
  value       = var.client_count
}

# ============================================================================
# DEPLOYMENT INFO - Structured information for automation scripts
# ============================================================================

output "deployment_info" {
  description = "Structured deployment information for automation scripts"
  value = {
    cluster_name        = local.cluster_name
    node_count          = 2
    region              = var.region
    zone                = var.zone
    machine_type        = local.selected_machine_type
    node1_name          = google_compute_instance.mayascale_nodes[0].name
    node1_zone          = google_compute_instance.mayascale_nodes[0].zone
    node1_external_ip   = var.assign_public_ip ? google_compute_instance.mayascale_nodes[0].network_interface[0].access_config[0].nat_ip : null
    node1_internal_ip   = google_compute_instance.mayascale_nodes[0].network_interface[0].network_ip
    node2_name          = google_compute_instance.mayascale_nodes[1].name
    node2_zone          = google_compute_instance.mayascale_nodes[1].zone
    node2_external_ip   = var.assign_public_ip ? google_compute_instance.mayascale_nodes[1].network_interface[0].access_config[0].nat_ip : null
    node2_internal_ip   = google_compute_instance.mayascale_nodes[1].network_interface[0].network_ip
    vip_primary         = local.vip_address
    vip_secondary       = local.vip_address_2
    total_nvme_count    = local.active_policy.local_ssd_count * 2
    total_capacity_gb   = local.active_policy.local_ssd_count * 375 * 2
  }
}

