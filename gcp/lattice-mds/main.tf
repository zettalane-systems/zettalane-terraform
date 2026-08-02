# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# GCP Lattice pNFS Metadata Server (MDS) Module
#
# Single VM that runs the Lattice user-space pNFS metadata
# server plus a co-located single-node RonDB (ndb_mgmd + ndbmtd,
# NoOfReplicas=1). The data servers are EXTERNAL — two MayaNAS active-active
# VIP/NFS shares wired in via setup-lattice-mds.sh (ds[0]/ds[1]).
#
# For the HA variant (2 data nodes on their own VMs) scale this out later;
# this module is the smoke/kick-the-tires single-box MDS.

provider "google" {
  project = var.project_id
}

data "google_compute_network" "default" {
  name    = "default"
  project = var.project_id
}

# Same-VPC/zone colocation with the MayaNAS storage nodes + client (optional).
data "google_compute_resource_policy" "placement_policy" {
  count   = var.placement_policy_name != "" ? 1 : 0
  name    = var.placement_policy_name
  region  = replace(var.zone, "/-[a-z]$/", "")
  project = var.project_id
}

data "google_compute_default_service_account" "default" {
  project = var.project_id
}

locals {
  # TIER_1 networking needs 30+ vCPUs; extract vCPU count from the machine type.
  mds_vcpus               = tonumber(regex("-(\\d+)(?:-.*)?$", var.machine_type)[0])
  enable_tier1_networking = local.mds_vcpus >= 30

  # C4/C4D/C3/C3D require hyperdisk-balanced; everything else takes pd-ssd
  # (fast redo/LCP for RonDB).
  boot_disk_type = (
    startswith(var.machine_type, "c4-") ||
    startswith(var.machine_type, "c4d-") ||
    startswith(var.machine_type, "c3-") ||
    startswith(var.machine_type, "c3d-")
  ) ? "hyperdisk-balanced" : "pd-ssd"
}

resource "google_compute_instance" "mds" {
  name         = var.mds_name
  machine_type = var.machine_type
  zone         = var.zone
  project      = var.project_id

  resource_policies = var.placement_policy_name != "" ? [
    data.google_compute_resource_policy.placement_policy[0].id
  ] : []

  boot_disk {
    initialize_params {
      image = var.source_image
      size  = var.boot_disk_gb # RonDB DataDir (redo + LCP) + build tree
      type  = local.boot_disk_type
    }
  }

  network_interface {
    network  = data.google_compute_network.default.id
    nic_type = "GVNIC"
    access_config {
      network_tier = "PREMIUM"
    }
  }

  dynamic "network_performance_config" {
    for_each = local.enable_tier1_networking ? [1] : []
    content {
      total_egress_bandwidth_tier = "TIER_1"
    }
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yaml", {
      ssh_public_key = var.ssh_public_key
      admin_username = var.admin_username
    })
  }

  service_account {
    email  = data.google_compute_default_service_account.default.email
    scopes = ["cloud-platform"]
  }

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

  dynamic "scheduling" {
    for_each = !var.use_spot && var.placement_policy_name != "" ? [1] : []
    content {
      automatic_restart   = false
      on_host_maintenance = "TERMINATE"
    }
  }
}
