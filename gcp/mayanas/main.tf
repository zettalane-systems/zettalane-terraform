# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Configure the Google Cloud Provider
provider "google" {
  project = var.project_id
  region  = var.region
}

# Generate unique suffix for resources
resource "random_id" "suffix" {
  byte_length = 4
}

# Generate random password for MayaNAS instances
resource "random_password" "mayanas_password" {
  length  = 16
  special = true
  upper   = true
  lower   = true
  numeric = true
}

# Generate cluster resource IDs for unique naming (dual for active-active)
resource "random_integer" "resource_id" {
  min = 1
  max = 255
}

resource "random_integer" "peer_resource_id" {
  min = 1
  max = 255
}

# Check for existing mayanas-alias-range in target subnet and VPC-wide ranges with region info
data "external" "range_analysis" {
  program = ["bash", "-c", <<-EOT
    # Get all secondary ranges across VPC (simple list for conflict detection)
    all_ranges=$(gcloud compute networks subnets list \
      --format='value(secondaryIpRanges[].ipCidrRange)' \
      --filter='network:${var.network_name}' \
      --quiet 2>/dev/null | tr '\n' ',' | sed 's/,$//') || all_ranges=""
    
    # Get detailed subnet info with regions for debugging  
    ranges_with_regions=$(gcloud compute networks subnets list \
      --format='table[no-heading](region,name,secondaryIpRanges[].ipCidrRange:label="")' \
      --filter='network:${var.network_name}' \
      --quiet 2>/dev/null | while read -r region subnet ranges; do
        if [ -n "$ranges" ] && [ "$ranges" != "-" ]; then
          echo "$region/$subnet:$ranges"
        fi
      done | tr '\n' ',' | sed 's/,$//') || ranges_with_regions=""
    
    # Check for existing mayanas-alias-range in target subnet
    target_subnet="${var.subnet_name != "" ? var.subnet_name : "default"}"
    existing_mayanas=$(gcloud compute networks subnets describe "$target_subnet" \
      --region="${var.region}" \
      --format='value(secondaryIpRanges[].rangeName,secondaryIpRanges[].ipCidrRange)' \
      --quiet 2>/dev/null | grep "mayanas-alias-range" | cut -f2 -d$'\t' || echo "")
    
    echo "{\"vpc_ranges\": \"$all_ranges\", \"vpc_ranges_with_regions\": \"$ranges_with_regions\", \"existing_mayanas_range\": \"$existing_mayanas\"}"
  EOT
  ]
}

# Calculate dual VIP addresses with intelligent range discovery
locals {
  # Get current subnet information
  subnet_primary_cidr = data.google_compute_subnetwork.default.ip_cidr_range
  
  # Parse range analysis data
  ranges_string = data.external.range_analysis.result.vpc_ranges
  all_ranges_raw = local.ranges_string != "" ? split(",", local.ranges_string) : []
  all_secondary_ranges = [for range in local.all_ranges_raw : range if range != ""]
  
  # Parse region information for ranges
  ranges_with_regions_string = data.external.range_analysis.result.vpc_ranges_with_regions
  ranges_with_regions_raw = local.ranges_with_regions_string != "" ? split(",", local.ranges_with_regions_string) : []
  ranges_with_regions = [for item in local.ranges_with_regions_raw : item if item != ""]
  
  # Check for existing mayanas-alias-range in target subnet
  existing_mayanas_range = data.external.range_analysis.result.existing_mayanas_range
  
  # Determine if we can reuse existing mayanas-alias-range
  can_reuse_existing = (
    local.existing_mayanas_range != "" && 
    startswith(local.existing_mayanas_range, "10.100.")
  )
  
  # Use region-based deterministic hash for VIP range selection (marketplace-package approach)
  # Simple deterministic hash using region name
  region_hash = sum([for i, char in split("", var.region) : (i + 1) * 3])
  default_range_index = local.region_hash % 256
  default_vip_cidr_range = "10.100.${local.default_range_index}.0/24"
  
  # Create /24 candidate ranges starting from region-based hash to avoid common conflicts
  candidate_ranges = [
    for i in range(0, 256) : "10.100.${(local.default_range_index + i) % 256}.0/24"
  ]
  
  # Find first /24 range that doesn't conflict with existing secondary ranges across VPC
  available_ranges = [for range in local.candidate_ranges : range if !contains(local.all_secondary_ranges, range)]
  auto_selected_range = length(local.available_ranges) > 0 ? local.available_ranges[0] : local.default_vip_cidr_range
  
  # Use existing range if possible, manual override, or auto-selected range
  # Only assign VIP range for HA deployments (not single)
  vip_cidr_range = var.deployment_type == "single" ? "" : (
    local.can_reuse_existing ? local.existing_mayanas_range : (
      var.vip_cidr_range != "" ? var.vip_cidr_range : local.auto_selected_range
    )
  )
  
  # Extract IP range information for VIP calculation (only for HA deployments)
  range_parts = local.vip_cidr_range != "" ? split("/", local.vip_cidr_range) : ["", ""]
  range_base_ip = local.vip_cidr_range != "" ? local.range_parts[0] : ""
  base_ip_parts = local.range_base_ip != "" ? split(".", local.range_base_ip) : ["", "", "", ""]
  
  # Calculate dual VIP addresses within the /24 range.
  #
  # Two strategies:
  #   pair_index >  0  →  deterministic slot assignment. Each pair owns 2
  #                       contiguous IPs; pair N uses (2*N+1, 2*N+2). Guarantees
  #                       zero overlap when stacking multiple HA pairs in the
  #                       same /24 (Lustre join, multi-pair deployments).
  #   pair_index == 0  →  random offset based on random_id.suffix.dec. Backward
  #                       compatible for single-pair deployments.
  full_random_value = random_id.suffix.dec
  vip_offset1 = var.pair_index > 0 ? (var.pair_index * 2 + 1) : ((local.full_random_value % 254) + 1)
  vip_offset2 = var.pair_index > 0 ? (var.pair_index * 2 + 2) : ((floor(local.full_random_value / 256) % 254) + 1)
  vip_offset2_final = local.vip_offset1 == local.vip_offset2 ? ((local.vip_offset2 % 254) + 1) : local.vip_offset2
  
  # VIP addresses based on deployment type
  # Active-active gets dual VIPs, active-passive gets one VIP, single gets no VIP
  vip_node1_address = var.deployment_type != "single" ? "${local.base_ip_parts[0]}.${local.base_ip_parts[1]}.${local.base_ip_parts[2]}.${local.vip_offset1}" : ""
  vip_node2_address = var.deployment_type == "active-active" ? "${local.base_ip_parts[0]}.${local.base_ip_parts[1]}.${local.base_ip_parts[2]}.${local.vip_offset2_final}" : ""
  
  # Single alias IP range name for both nodes (active-active shares one range)
  alias_range_name = "mayanas-alias-range"
  
  # Smart zone selection: use zones array or hash-based auto-select to spread load  
  zone_count = length(data.google_compute_zones.available.names)
  zone_offset = parseint(substr(random_id.suffix.hex, 2, 2), 16) % local.zone_count
  
  node1_zone = length(var.zones) > 0 ? var.zones[0] : data.google_compute_zones.available.names[local.zone_offset]
  node2_zone = length(var.zones) > 1 ? var.zones[1] : (
    length(var.zones) == 1 ? var.zones[0] : (
      var.multi_zone ? data.google_compute_zones.available.names[(local.zone_offset + 1) % local.zone_count] : data.google_compute_zones.available.names[local.zone_offset]
    )
  )
  
  
  # Variable bucket management based on deployment type
  # Active-active gets resources per node, others share resources
  total_bucket_count = var.deployment_type == "active-active" ? var.bucket_count * 2 : var.bucket_count
  total_metadata_disk_count = var.deployment_type == "active-active" ? var.metadata_disk_count * 2 : var.metadata_disk_count
  
  # All bucket and disk names for startup script configuration
  bucket_names = [for bucket in google_storage_bucket.mayanas_data : bucket.name]
  metadata_disk_names = var.multi_zone ? [for disk in google_compute_region_disk.mayanas_metadata_regional : disk.name] : [for disk in google_compute_disk.mayanas_metadata_zonal : disk.name]
  
  # Trim cluster name to ensure service account ID stays within 30 char limit
  # Format: "{trimmed_cluster_name}-{6_char_hex}" must be ≤ 30 chars
  # So cluster name can be max 23 chars (30 - 1 dash - 6 hex chars)
  trimmed_cluster_name = length(var.cluster_name) > 23 ? substr(var.cluster_name, 0, 23) : var.cluster_name
  
  # Consistent 6-character suffix for all resources (service account length limit)
  resource_suffix = substr(random_id.suffix.hex, 0, 6)

  # Extract vCPU count from machine type to determine TIER_1 eligibility
  # Works for all machine families: n2-standard-32, c4-standard-48, c4-standard-48-lssd, etc.
  # Regex captures digits after last dash before optional suffix: -(\\d+)(?:-.*)?$
  # TIER_1 requires 30+ vCPUs (applies to N2, C3, C3D, C4, N4, etc.)
  machine_type_vcpus = tonumber(regex("-(\\d+)(?:-.*)?$", var.machine_type)[0])
  enable_tier1_networking = local.machine_type_vcpus >= 30

  # Auto-select boot disk type based on machine type
  # N4 instances require Hyperdisk, C4/C4A also require Hyperdisk
  # All other instances support Persistent Disk types
  is_n4_or_c4 = can(regex("^(n4|c4|c4a)-", var.machine_type))
  auto_boot_disk_type = local.is_n4_or_c4 ? "hyperdisk-balanced" : "pd-balanced"

  # Use auto-selected type if var.boot_disk_type is "auto", otherwise use specified type
  boot_disk_type = var.boot_disk_type == "auto" ? local.auto_boot_disk_type : var.boot_disk_type

  # Auto-select metadata disk type based on machine type
  # N4/C4 require Hyperdisk for all disks, others use pd-ssd for performance
  auto_metadata_disk_type = local.is_n4_or_c4 ? "hyperdisk-balanced" : "pd-ssd"

  # Use auto-selected type if var.metadata_disk_type is "auto", otherwise use specified type
  metadata_disk_type = var.metadata_disk_type == "auto" ? local.auto_metadata_disk_type : var.metadata_disk_type

  # Image path: use specific image if set, otherwise use image family for "latest"
  source_image_path = var.source_image != "" ? (
    "projects/${var.source_image_project}/global/images/${var.source_image}"
  ) : (
    "projects/${var.source_image_project}/global/images/family/${var.source_image_family}"
  )
}

# Essential VIP information for users
output "vip_info" {
  description = "VIP range and calculated dual address information"
  value = {
    existing_mayanas_range = local.existing_mayanas_range
    existing_range_reused = local.can_reuse_existing
    vip_range = local.vip_cidr_range
    node1_calculated_vip = local.vip_node1_address
    node2_calculated_vip = local.vip_node2_address
    vpc_ranges_with_regions = local.ranges_with_regions
  }
}


# Validation check to ensure we found an available range or can reuse existing
check "available_range_found" {
  assert {
    condition = local.can_reuse_existing || var.vip_cidr_range != "" || local.auto_selected_range != "ERROR_NO_AVAILABLE_RANGE"
    error_message = <<-EOT
      ❌ NO AVAILABLE SECONDARY IP RANGE FOUND ❌
      
      PROBLEM: All 256 candidate /24 ranges (10.100.0.0/24 - 10.100.255.0/24) are already in use across VPC.
      
      PRIMARY SUBNET: ${local.subnet_primary_cidr}
      EXISTING MAYANAS RANGE: ${local.existing_mayanas_range}
      EXISTING RANGES ACROSS ENTIRE VPC:
      ${join("\n      ", local.all_secondary_ranges)}
      
      CORRECTIVE ACTIONS:
      1. Check other regions - some may be using 10.100.x.0/24 ranges:
         gcloud compute networks subnets list --format="table(name,region,secondaryIpRanges[].ipCidrRange)" --filter="network:${var.network_name}"
      
      2. Use manual override by finding available range and setting:
         vip_cidr_range = "10.100.{available_third_octet}.0/24"
      
      3. Remove unused secondary IP ranges from subnets across the VPC
      4. Consider using different IP space (contact administrator)
    EOT
  }
}


# No primary subnet conflict possible - 10.100.x.0/24 never conflicts with GCP default subnets

# Note: Dual VIP address validation happens at apply time due to random generation
# The final VIPs will be within the allocated /24 range (startup script handles collision detection)

# Data sources
data "google_compute_zones" "available" {
  region = var.region
}

# Data sources for existing default network
data "google_compute_network" "default" {
  name = var.network_name
}

data "google_compute_subnetwork" "default" {
  name   = var.subnet_name != "" ? var.subnet_name : "default"
  region = var.region
}

# When VMs have no public IP, they also have no route to the internet —
# including *.googleapis.com. The startup script shells out to gcloud, which
# then fails with "Network is unreachable" and cluster setup never completes.
# Private Google Access routes *.googleapis.com traffic over Google's internal
# fabric, fixing this without needing a NAT gateway. Idempotent; leaving it
# on after `terraform destroy` is harmless.
#
# We PATCH the subnet directly via the Compute REST API using the same OAuth
# token the google provider already holds. No gcloud dependency in the PATH,
# no subnet import / state ownership complication.
data "google_client_config" "default" {}

resource "null_resource" "enable_private_google_access" {
  count = var.assign_public_ip ? 0 : 1

  triggers = {
    subnet  = data.google_compute_subnetwork.default.self_link
    region  = var.region
    project = var.project_id
  }

  provisioner "local-exec" {
    # Pass the token via env to keep it out of command-line / plan output.
    environment = {
      GCP_TOKEN = data.google_client_config.default.access_token
    }

    # Dedicated API method — no fingerprint needed, unlike the generic
    # subnetworks.patch which rejects partial updates without one.
    # Returns an LRO (operation) object; we don't need to poll because PGA
    # propagates in <5s and the VMs don't boot until this resource succeeds.
    command = <<-EOT
      curl -sSf -X POST \
        -H "Authorization: Bearer $GCP_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"privateIpGoogleAccess": true}' \
        "https://compute.googleapis.com/compute/v1/projects/${var.project_id}/regions/${var.region}/subnetworks/${data.google_compute_subnetwork.default.name}/setPrivateIpGoogleAccess"
    EOT
  }
}

# Service Account for MayaNAS instances
resource "google_service_account" "mayanas_sa" {
  account_id   = "${local.trimmed_cluster_name}-${local.resource_suffix}"
  display_name = "MayaNAS HA Service Account"
  description  = "Service account for MayaNAS HA cluster instances"
}

# IAM bindings for service account
resource "google_project_iam_member" "mayanas_compute_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.mayanas_sa.email}"
}

resource "google_project_iam_member" "mayanas_network_admin" {
  project = var.project_id
  role    = "roles/compute.networkAdmin"
  member  = "serviceAccount:${google_service_account.mayanas_sa.email}"
}

resource "google_project_iam_member" "mayanas_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.mayanas_sa.email}"
}

resource "google_project_iam_member" "mayanas_service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.mayanas_sa.email}"
}

# No Secret Manager access needed - HMAC key passed directly

# GCS buckets for shared data storage (scalable array)
resource "google_storage_bucket" "mayanas_data" {
  count = local.total_bucket_count
  
  name          = "${var.cluster_name}-mayanas-data-${count.index}-${local.resource_suffix}"
  location      = var.region
  storage_class = "STANDARD"
  force_destroy = var.force_destroy_buckets
  
  uniform_bucket_level_access = true
  
  versioning {
    enabled = false
  }
  
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
  
  labels = {
    environment = var.environment
    cluster     = var.cluster_name
    purpose     = "mayanas-data-storage"
    bucket_index = tostring(count.index)
    # Node assignment for active-active: first half to node1, second half to node2
    node_assignment = count.index < var.bucket_count ? "node1" : "node2"
  }
}

# Create shared HMAC key for GCS access (all nodes use the same key)
resource "google_storage_hmac_key" "mayanas_hmac" {
  service_account_email = google_service_account.mayanas_sa.email
}

# Create metadata disks (SSD) - Zonal for single-zone deployments  
resource "google_compute_disk" "mayanas_metadata_zonal" {
  count = var.multi_zone ? 0 : local.total_metadata_disk_count
  
  name = "${var.cluster_name}-mayanas-metadata-${count.index}-${local.resource_suffix}"
  type = local.metadata_disk_type
  zone = count.index < var.metadata_disk_count ? local.node1_zone : local.node2_zone
  size = var.metadata_disk_size_gb

  labels = {
    environment = var.environment
    cluster     = var.cluster_name
    purpose     = "mayanas-metadata-storage"
    deployment  = "zonal"
    disk_index = tostring(count.index)
    # Node assignment for active-active: first half to node1, second half to node2
    node_assignment = count.index < var.metadata_disk_count ? "node1" : "node2"
  }
}

# Regional metadata disks (used when multi_zone = true)
resource "google_compute_region_disk" "mayanas_metadata_regional" {
  count = var.multi_zone ? local.total_metadata_disk_count : 0
  
  name   = "${var.cluster_name}-mayanas-metadata-${count.index}-${local.resource_suffix}"
  type   = var.metadata_disk_type
  region = var.region
  size   = var.metadata_disk_size_gb
  
  replica_zones = [local.node1_zone, local.node2_zone]

  labels = {
    environment = var.environment
    cluster     = var.cluster_name
    purpose     = "mayanas-metadata-storage"
    deployment  = "regional"
    disk_index = tostring(count.index)
    # Node assignment for active-active: first half to node1, second half to node2
    node_assignment = count.index < var.metadata_disk_count ? "node1" : "node2"
  }
}

# Lustre MDT disk (pd-ssd for low-latency metadata operations)
# MDT must be on NVMe/SSD — GCS round-trips kill metadata performance
# Skipped in join mode: the remote MGS already hosts the MDT for this fs.
resource "google_compute_disk" "lustre_mdt" {
  count = var.enable_lustre && var.lustre_join_mgs_nid == "" ? 1 : 0

  name = "${var.cluster_name}-lustre-mdt-${local.resource_suffix}"
  type = local.metadata_disk_type
  zone = local.node1_zone
  size = var.lustre_mdt_disk_size_gb

  labels = {
    environment = var.environment
    cluster     = var.cluster_name
    purpose     = "lustre-mdt"
  }
}

# Note: We use the existing default subnet and configure alias IP ranges on instances
# No need to create a new subnetwork - GCP will handle alias IP ranges automatically

# Firewall rule for SSH access (direct, when IAP is disabled)
resource "google_compute_firewall" "mayanas_ssh" {
  count   = var.enable_iap ? 0 : 1
  name    = "${var.cluster_name}-mayanas-ssh-${local.resource_suffix}"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = ["mayanas-${var.cluster_name}"]
}

# Firewall rule for IAP SSH tunnel (project-wide, shared across deployments)
resource "google_compute_firewall" "mayanas_iap_ssh" {
  count   = var.enable_iap ? 1 : 0
  name    = "mayanas-allow-iap-ssh"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  description   = "Allow SSH via IAP tunnel to all MayaNAS instances"
}

# Firewall rule for internal communication between nodes
resource "google_compute_firewall" "mayanas_internal" {
  name    = "${var.cluster_name}-mayanas-internal-${local.resource_suffix}"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_tags = ["mayanas-${var.cluster_name}"]
  target_tags = ["mayanas-${var.cluster_name}"]
}

# Firewall rule for VIP access across regions/zones  
resource "google_compute_firewall" "mayanas_vip_access" {
  name    = "${var.cluster_name}-mayanas-vip-${local.resource_suffix}"
  network = data.google_compute_network.default.name

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  # Allow access from the same region's subnet ranges
  source_ranges = [data.google_compute_subnetwork.default.ip_cidr_range]
  description   = "Allow regional access to MayaNAS VIP alias IP range (10.100.0.0/24)"
}

# Template for node1 startup script (only node1 needs startup script)
data "template_file" "startup_script_node1" {
  template = file("${path.module}/startup.sh.tpl")
  vars = {
    deployment_type     = var.deployment_type
    cluster_name         = var.cluster_name
    node_role           = var.deployment_type == "active-active" ? "node1" : "primary"
    vip_address         = local.vip_node1_address
    vip_address_2       = local.vip_node2_address
    bucket_names        = join(" ", local.bucket_names)
    gcs_bucket          = join(" ", local.bucket_names)
    metadata_disk       = join(" ", local.metadata_disk_names)
    peer_zone           = local.node2_zone
    metadata_disk_names = join(" ", local.metadata_disk_names)
    vip_cidr_range      = local.vip_cidr_range
    resource_id         = random_integer.resource_id.result
    random_resource_id  = random_integer.resource_id.result
    peer_resource_id    = random_integer.peer_resource_id.result
    gcs_access_key      = google_storage_hmac_key.mayanas_hmac.access_id
    gcs_secret_key      = google_storage_hmac_key.mayanas_hmac.secret
    project_id          = var.project_id
    primary_zone        = local.node1_zone
    secondary_zone      = local.node2_zone
    # Shares configuration (fsid added by cluster_setup2.sh per node)
    shares              = jsonencode(var.shares)
    random_suffix       = local.resource_suffix
    mayanas_startup_wait = var.mayanas_startup_wait != null ? tostring(var.mayanas_startup_wait) : ""
    bucket_count        = var.bucket_count
    blocksize           = var.blocksize
    subnet_cidr         = data.google_compute_subnetwork.default.ip_cidr_range
    enable_lustre        = var.enable_lustre
    lustre_fsname        = var.fsname
    lustre_dom_threshold = var.dom_threshold
    lustre_mdt_disk_names = var.enable_lustre && var.lustre_join_mgs_nid == "" ? join(" ", [for disk in google_compute_disk.lustre_mdt : disk.name]) : ""
    lustre_mdt_backend    = var.lustre_mdt_backend
    lustre_join_mgs_nid   = var.lustre_join_mgs_nid
  }
}


# Node 1 MayaNAS instance
resource "google_compute_instance" "mayanas_node1" {
  name         = var.deployment_type == "active-active" ? "${var.cluster_name}-mayanas-node1-${local.resource_suffix}" : "${var.cluster_name}-mayanas-primary-${local.resource_suffix}"
  machine_type = var.machine_type
  zone         = local.node1_zone

  tags = ["mayanas-${var.cluster_name}", "mayanas-node1"]

  # Request Intel Ice Lake CPUs for N2 instances (better network and CPU performance)
  # Ice Lake: +18% IPC, better network offload vs Skylake/Cascade Lake
  # Only applies to n2-* instances (Intel), ignored for AMD (N2D) or ARM (T2A)
  min_cpu_platform = startswith(var.machine_type, "n2-") ? "Intel Ice Lake" : null

  boot_disk {
    initialize_params {
      image = local.source_image_path
      size  = var.boot_disk_size_gb
      type  = local.boot_disk_type
    }
  }

  # Attach all metadata disks to node1 for cluster setup (marketplace-package pattern)
  dynamic "attached_disk" {
    for_each = range(local.total_metadata_disk_count)
    content {
      source      = var.multi_zone ? google_compute_region_disk.mayanas_metadata_regional[attached_disk.key].id : google_compute_disk.mayanas_metadata_zonal[attached_disk.key].id
      device_name = var.multi_zone ? google_compute_region_disk.mayanas_metadata_regional[attached_disk.key].name : google_compute_disk.mayanas_metadata_zonal[attached_disk.key].name
      mode        = "READ_WRITE"
    }
  }

  # Attach Lustre MDT disk to node1 (skipped in join mode — see disk count guard above)
  dynamic "attached_disk" {
    for_each = var.enable_lustre && var.lustre_join_mgs_nid == "" ? [1] : []
    content {
      source      = google_compute_disk.lustre_mdt[0].id
      device_name = google_compute_disk.lustre_mdt[0].name
      mode        = "READ_WRITE"
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.default.id
    nic_type   = "GVNIC"  # Google Virtual NIC: better performance than VirtIO, required for TIER_1

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {
        network_tier = "PREMIUM"
      }
    }
  }

  # Enable TIER_1 networking for maximum bandwidth (only for 30+ vCPU machines)
  # Examples: n2-highcpu-32 (~50 Gbps), c4-standard-48 (~75 Gbps)
  # TIER_1 requires 30+ vCPUs, bandwidth scales with vCPU count
  # Machines with <30 vCPUs will use default tier (TIER_DEFAULT ~8-16 Gbps)
  dynamic "network_performance_config" {
    for_each = local.enable_tier1_networking ? [1] : []
    content {
      total_egress_bandwidth_tier = "TIER_1"
    }
  }

  service_account {
    email  = google_service_account.mayanas_sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    ssh-keys = var.ssh_public_key != "" ? "mayanas:${var.ssh_public_key}" : ""
    mayanas-cluster-name = var.cluster_name
    mayanas-node-role = "node1"
    mayanas-vip = local.vip_node1_address
    mayanas-bucket = join(" ", local.bucket_names)
    mayanas-peer-zone = local.node2_zone
    mayanas-cloud_user_password = random_password.mayanas_password.result
  }

  metadata_startup_script = data.template_file.startup_script_node1.rendered

  dynamic "scheduling" {
    for_each = var.use_spot_vms ? [1] : []
    content {
      preemptible        = true
      automatic_restart  = false
      on_host_maintenance = "TERMINATE"
    }
  }

  lifecycle {
    ignore_changes = [attached_disk]
  }

  depends_on = [
    google_project_iam_member.mayanas_compute_admin,
    google_project_iam_member.mayanas_network_admin,
    google_project_iam_member.mayanas_storage_admin,
    google_project_iam_member.mayanas_service_account_user,
    null_resource.enable_private_google_access
  ]
}

# Node 2 MayaNAS instance
resource "google_compute_instance" "mayanas_node2" {
  count = var.deployment_type != "single" ? 1 : 0

  name         = var.deployment_type == "active-active" ? "${var.cluster_name}-mayanas-node2-${local.resource_suffix}" : "${var.cluster_name}-mayanas-secondary-${local.resource_suffix}"
  machine_type = var.machine_type
  zone         = local.node2_zone

  tags = ["mayanas-${var.cluster_name}", "mayanas-node2"]

  # Request Intel Ice Lake CPUs for N2 instances (better network and CPU performance)
  # Ice Lake: +18% IPC, better network offload vs Skylake/Cascade Lake
  # Only applies to n2-* instances (Intel), ignored for AMD (N2D) or ARM (T2A)
  min_cpu_platform = startswith(var.machine_type, "n2-") ? "Intel Ice Lake" : null

  boot_disk {
    initialize_params {
      image = local.source_image_path
      size  = var.boot_disk_size_gb
      type  = local.boot_disk_type
    }
  }

  # No metadata disk attached - node1 has both disks for cluster setup

  network_interface {
    subnetwork = data.google_compute_subnetwork.default.id
    nic_type   = "GVNIC"  # Google Virtual NIC: better performance than VirtIO, required for TIER_1

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {
        network_tier = "PREMIUM"
      }
    }
  }

  # Enable TIER_1 networking for maximum bandwidth (only for 30+ vCPU machines)
  # Examples: n2-highcpu-32 (~50 Gbps), c4-standard-48 (~75 Gbps)
  # TIER_1 requires 30+ vCPUs, bandwidth scales with vCPU count
  # Machines with <30 vCPUs will use default tier (TIER_DEFAULT ~8-16 Gbps)
  dynamic "network_performance_config" {
    for_each = local.enable_tier1_networking ? [1] : []
    content {
      total_egress_bandwidth_tier = "TIER_1"
    }
  }

  service_account {
    email  = google_service_account.mayanas_sa.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    ssh-keys = var.ssh_public_key != "" ? "mayanas:${var.ssh_public_key}" : ""
    mayanas-cluster-name = var.cluster_name
    mayanas-node-role = "node2"
    mayanas-vip = local.vip_node2_address
    mayanas-bucket = join(" ", local.bucket_names)
    mayanas-peer-zone = local.node1_zone
    mayanas-cloud_user_password = random_password.mayanas_password.result
  }

  # No startup script needed - node2 joins cluster automatically

  dynamic "scheduling" {
    for_each = var.use_spot_vms ? [1] : []
    content {
      preemptible        = true
      automatic_restart  = false
      on_host_maintenance = "TERMINATE"
    }
  }

  lifecycle {
    ignore_changes = [attached_disk]
  }

  depends_on = [
    google_project_iam_member.mayanas_compute_admin,
    google_project_iam_member.mayanas_network_admin,
    google_project_iam_member.mayanas_storage_admin,
    google_project_iam_member.mayanas_service_account_user,
    null_resource.enable_private_google_access
  ]
}

