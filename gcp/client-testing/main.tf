# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# GCP Client Testing Module - Ubuntu Client for NFS Testing

provider "google" {
  project = var.project_id
}

data "google_compute_network" "default" {
  name    = "default"
  project = var.project_id
}

# Look up placement policy for colocation with storage nodes
data "google_compute_resource_policy" "placement_policy" {
  count   = var.placement_policy_name != "" ? 1 : 0
  name    = var.placement_policy_name
  region  = replace(var.zone, "/-[a-z]$/", "")
  project = var.project_id
}

resource "google_compute_instance" "client" {
  name         = var.client_name
  machine_type = var.machine_type
  zone         = var.zone
  project      = var.project_id

  # Join placement policy for colocation with storage
  resource_policies = var.placement_policy_name != "" ? [
    data.google_compute_resource_policy.placement_policy[0].id
  ] : []

  boot_disk {
    initialize_params {
      image = var.source_image
      size  = 50
      # C4, C4D, C3, C3D require hyperdisk-balanced (don't support pd-balanced)
      type  = (
        startswith(var.machine_type, "c4-") ||
        startswith(var.machine_type, "c4d-") ||
        startswith(var.machine_type, "c3-") ||
        startswith(var.machine_type, "c3d-")
      ) ? "hyperdisk-balanced" : "pd-balanced"
    }
  }

  network_interface {
    network = data.google_compute_network.default.id
    access_config {
      network_tier = "PREMIUM"
    }
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yaml", {
      ssh_public_key = var.ssh_public_key
      admin_username = var.admin_username
    })
  }

  # Spot instances
  dynamic "scheduling" {
    for_each = var.use_spot ? [1] : []
    content {
      preemptible                 = true
      automatic_restart           = false
      on_host_maintenance         = "TERMINATE"
      provisioning_model          = "SPOT"
      instance_termination_action = "STOP"
    }
  }

  # On-demand with colocation (COLLOCATED requires automatic_restart = false)
  dynamic "scheduling" {
    for_each = !var.use_spot && var.placement_policy_name != "" ? [1] : []
    content {
      automatic_restart   = false
      on_host_maintenance = "TERMINATE"
    }
  }

}
