provider "google" {
  project = var.project_id
}

# Auto-derive region from zone
locals {
  derived_region = regex("^([a-z]+-[a-z]+[0-9]+)", var.zone)[0]

  # Image path: use specific image if set, otherwise use image family for "latest"
  source_image_path = var.source_image != "" ? (
    "projects/${var.source_image_project}/global/images/${var.source_image}"
  ) : (
    "projects/${var.source_image_project}/global/images/family/${var.source_image_family}"
  )
}

# Generate unique suffix for resources
resource "random_id" "suffix" {
  byte_length = 4
}

# Generate cluster resource IDs for unique naming (matching MayaNAS pattern)
resource "random_integer" "resource_id" {
  min = 1
  max = 255
}

# Second resource ID for active-active deployments
resource "random_integer" "peer_resource_id" {
  min = 1
  max = 255
}

# Generate random password for MayaScale instances
resource "random_password" "mayascale_password" {
  length  = 16
  special = true
  upper   = true
  lower   = true
  numeric = true
}

# GCP Marketplace Simplified VIP Range Management
# Calculate VIP address with simplified marketplace-compatible logic
locals {
  # Simple deterministic hash using region name
  region_hash = sum([for i, char in split("", local.derived_region) : (i + 1) * 3])
  default_range_index = local.region_hash % 256
  default_vip_cidr_range = "10.100.${local.default_range_index}.0/24"

  # Use region-based default VIP range
  vip_cidr_range = local.default_vip_cidr_range

  # Extract IP range information for VIP calculation
  range_parts = split("/", local.vip_cidr_range)
  range_base_ip = local.range_parts[0]
  base_ip_parts = split(".", local.range_base_ip)

  # Calculate VIP addresses within the /24 range using random value
  full_random_value = random_id.suffix.dec

  # Calculate VIP offsets within the available range (1-254 for /24) - matching MayaNAS logic
  vip_offset1 = (local.full_random_value % 254) + 1
  vip_offset2 = (floor(local.full_random_value / 256) % 254) + 1

  # Final VIP addresses: 10.100.{third_octet}.{random_offset}
  vip_address = "${local.base_ip_parts[0]}.${local.base_ip_parts[1]}.${local.base_ip_parts[2]}.${local.vip_offset1}"
  vip_address_2 = "${local.base_ip_parts[0]}.${local.base_ip_parts[1]}.${local.base_ip_parts[2]}.${local.vip_offset2}"

  # MayaScale deployment configuration
  cluster_name = var.cluster_name

  # Placement policy ID - use existing policy if provided, otherwise use created policy
  placement_policy_id = (
    var.placement_policy_name != "" ?
    (length(data.google_compute_resource_policy.existing_placement_policy) > 0 ?
      data.google_compute_resource_policy.existing_placement_policy[0].id : "") :
    (length(google_compute_resource_policy.mayascale_placement_policy) > 0 ?
      google_compute_resource_policy.mayascale_placement_policy[0].id : "")
  )
}

# Performance Policy Configurations (Hidden from user)
locals {
  policy_configs = {
    # Ultra-performance tiers (n2-highcpu-64, 16 NVMe, 75 Gbps Tier_1)
    # IOPS targets based on usable performance at <1ms latency (80% of measured)
    # Note: Peak IOPS can be 20-25% higher but with >1ms latency
    # Regional: Client in same zone as Node1 (reads local), writes have cross-zone RAID1 sync
    # Read IOPS: Same as zonal | Write IOPS: 0.90× of zonal (cross-zone sync overhead)
    "regional-ultra-performance" = {
      target_write_iops     = 720000   # 0.90× zonal (cross-zone RAID1 sync overhead)
      target_read_iops      = 1800000  # Same as zonal (client reads from same-zone Node1)
      target_write_latency  = 2000     # <2ms (cross-zone sync adds ~700µs vs zonal <1ms)
      target_bandwidth_mbps = 8500     # Same as zonal (network sufficient for throughput)
      availability_strategy = "cross-zone"
      capacity_optimization = "performance"
      nvme_requirement_gb   = 6000     # 16 SSDs × 375GB
      machine_type         = "n2-highcpu-64"
      local_ssd_count      = 16
    }

    "zonal-ultra-performance" = {
      target_write_iops     = 800000   # Measured: 866K @ 884µs (QD24/NJ32) <1ms. Marketing: clean "800K"
      target_read_iops      = 2000000  # Measured: 2.03M @ 1018µs (~1ms). Client 75Gbps may limit.
      target_write_latency  = 1000     # Actual at target IOPS: 884µs, 1ms = 1.1× safety margin
      target_bandwidth_mbps = 8500     # Measured: 10.3 GB/s read throughput
      availability_strategy = "same-zone"
      capacity_optimization = "performance"
      nvme_requirement_gb   = 6000     # 16 SSDs × 375GB
      machine_type         = "n2-highcpu-64"
      local_ssd_count      = 16
    }

    # High-performance tiers (n2-highcpu-32, 8 NVMe, 50 Gbps Tier_1)
    # IOPS targets based on usable performance at <1ms latency (80% of measured)
    # Note: Peak IOPS can be 25% higher but with >1ms latency
    # Regional: Client in same zone as Node1 (reads local), writes have cross-zone RAID1 sync
    "regional-high-performance" = {
      target_write_iops     = 315000   # 0.90× zonal (cross-zone RAID1 sync overhead)
      target_read_iops      = 900000   # Same as zonal (client reads from same-zone Node1)
      target_write_latency  = 2000     # <2ms (cross-zone sync adds ~700µs vs zonal <1ms)
      target_bandwidth_mbps = 5000     # Same as zonal
      availability_strategy = "cross-zone"
      capacity_optimization = "balanced"
      nvme_requirement_gb   = 3000     # 8 SSDs × 375GB
      machine_type         = "n2-highcpu-32"
      local_ssd_count      = 8
    }

    "zonal-high-performance" = {
      target_write_iops     = 350000   # Measured: 361K @ 883µs (QD16/NJ20) <1ms. Marketing: clean "350K"
      target_read_iops      = 900000   # Measured: 922K @ 830µs (QD24/NJ32) <1ms. Marketing: clean "900K"
      target_write_latency  = 1000     # Actual at target IOPS: 883µs, 1ms = 1.1× safety margin
      target_bandwidth_mbps = 5000     # Measured: 5.6 GB/s read throughput
      availability_strategy = "same-zone"
      capacity_optimization = "balanced"
      nvme_requirement_gb   = 3000     # 8 SSDs × 375GB (capacity tier, same IOPS as Medium)
      machine_type         = "n2-highcpu-32"
      local_ssd_count      = 8
    }

    # Medium-performance tiers (n2-highcpu-16, 4 NVMe, 32 Gbps)
    # IOPS targets based on usable performance at <1ms latency (80% of measured)
    # Note: Peak IOPS can be 9% higher but with >1ms latency
    # Regional: Client in same zone as Node1 (reads local), writes have cross-zone RAID1 sync
    "regional-medium-performance" = {
      target_write_iops     = 180000   # 0.90× zonal (cross-zone RAID1 sync overhead)
      target_read_iops      = 700000   # Same as zonal (client reads from same-zone Node1)
      target_write_latency  = 2000     # <2ms (cross-zone sync adds ~700µs vs zonal <1ms)
      target_bandwidth_mbps = 4000     # Same as zonal
      availability_strategy = "cross-zone"
      capacity_optimization = "balanced"
      nvme_requirement_gb   = 1500     # 4 SSDs × 375GB
      machine_type         = "n2-highcpu-16"
      local_ssd_count      = 4
    }

    "zonal-medium-performance" = {
      target_write_iops     = 200000   # Measured: 220K @ 872µs (QD16/NJ12) <1ms. Marketing: clean "200K"
      target_read_iops      = 700000   # Measured: 699K @ 822µs (QD24/NJ24) <1ms. Marketing: clean "700K"
      target_write_latency  = 1000     # Actual at target IOPS: 872µs, 1ms = 1.1× safety margin
      target_bandwidth_mbps = 4000     # Measured: 5.1 GB/s read throughput
      availability_strategy = "same-zone"
      capacity_optimization = "balanced"
      nvme_requirement_gb   = 1500     # 4 SSDs × 375GB (FIXED: was 750GB)
      machine_type         = "n2-highcpu-16"
      local_ssd_count      = 4
    }

    # Standard-performance tiers (n2-highcpu-8, 2 NVMe, 16 Gbps)
    # IOPS targets based on usable performance at <1ms latency (80% of measured)
    # Note: Peak IOPS can be 4% higher but with >1ms latency
    # Regional: Client in same zone as Node1 (reads local), writes have cross-zone RAID1 sync
    "regional-standard-performance" = {
      target_write_iops     = 120000   # 0.90× zonal (cross-zone RAID1 sync overhead)
      target_read_iops      = 380000   # Same as zonal (client reads from same-zone Node1)
      target_write_latency  = 2000     # <2ms (cross-zone sync adds ~700µs vs zonal <1ms)
      target_bandwidth_mbps = 2000     # Same as zonal
      availability_strategy = "cross-zone"
      capacity_optimization = "cost"
      nvme_requirement_gb   = 750      # 2 SSDs × 375GB
      machine_type         = "n2-highcpu-8"
      local_ssd_count      = 2
    }

    "zonal-standard-performance" = {
      target_write_iops     = 130000   # Measured: 136K @ 938µs (QD16/NJ8) <1ms. Marketing: clean "130K"
      target_read_iops      = 380000   # Measured: 388K @ 989µs (QD16/NJ24) <1ms. Marketing: clean "380K"
      target_write_latency  = 1000     # Actual at target IOPS: 938µs, 1ms = 1.1× safety margin
      target_bandwidth_mbps = 2000     # Measured: 2.5 GB/s read throughput
      availability_strategy = "same-zone"
      capacity_optimization = "cost"
      nvme_requirement_gb   = 750      # 2 SSDs × 375GB
      machine_type         = "n2-highcpu-8"
      local_ssd_count      = 2
    }

    # Regional: Client in same zone as Node1 (reads local), writes have cross-zone RAID1 sync
    "regional-basic-performance" = {
      target_write_iops     = 60000    # 0.90× zonal (cross-zone RAID1 sync overhead)
      target_read_iops      = 100000   # Same as zonal (client reads from same-zone Node1)
      target_write_latency  = 2000     # <2ms (cross-zone sync adds ~700µs vs zonal <1ms)
      target_bandwidth_mbps = 1000     # Same as zonal
      availability_strategy = "cross-zone"
      capacity_optimization = "cost"
      nvme_requirement_gb   = 375      # 1 SSD × 375GB per node
      machine_type         = "n2-highcpu-4"
      local_ssd_count      = 1
    }

    # Basic-performance tier (n2-highcpu-4, 1 NVMe, 10 Gbps)
    # IOPS targets based on usable performance at <1ms latency
    # Note: Single SSD hits thermal throttling at 146K read @ 15ms - not usable
    # See: PERFORMANCE_VALIDATION.md for detailed analysis
    "zonal-basic-performance" = {
      target_write_iops     = 75000    # Measured: 75K @ 858µs (QD16/NJ4) <1ms. Marketing: clean "75K"
      target_read_iops      = 100000   # Measured: 102K @ 630µs (QD16/NJ4) <1ms. Marketing: clean "100K"
      target_write_latency  = 1000     # Actual at target IOPS: 858µs, 1ms = 1.2× safety margin
      target_bandwidth_mbps = 1000     # Measured: 1.17 GB/s read throughput
      availability_strategy = "same-zone"
      capacity_optimization = "cost"
      nvme_requirement_gb   = 375      # 1 SSD × 375GB
      machine_type         = "n2-highcpu-4"
      local_ssd_count      = 1
    }
  }

  # Active policy configuration
  active_policy = local.policy_configs[var.performance_policy]

  # Machine type selection (user override or auto-selected)
  selected_machine_type = var.machine_type != "" ? var.machine_type : local.active_policy.machine_type

  # Extract vCPU count from machine type to determine TIER_1 eligibility
  # Works for all machine families: n2-highcpu-32, c4-standard-48, c4-standard-48-lssd, etc.
  # Regex captures digits after last dash before optional suffix: -(\\d+)(?:-.*)?$
  # TIER_1 requires 30+ vCPUs (applies to N2, C3, C3D, C4, N4, etc.)
  machine_type_vcpus = tonumber(regex("-(\\d+)(?:-.*)?$", local.selected_machine_type)[0])
  enable_tier1_networking = local.machine_type_vcpus >= 30

  # Zone strategy based on availability requirements
  available_zones = [
    "${var.region}-a",
    "${var.region}-b",
    "${var.region}-c"
  ]

  zone_strategy = local.active_policy.availability_strategy == "same-zone" ? [
    var.zone,  # Both nodes in same zone (different racks)
    var.zone
  ] : [
    var.zone,                    # Primary in specified zone
    local.available_zones[1]     # Secondary in different zone
  ]

  # Network configuration
  node_ips = [
    cidrhost("10.100.0.0/24", 10),  # Primary node IP
    cidrhost("10.100.0.0/24", 11)   # Secondary node IP
  ]

  # Backend network IPs for replication traffic
  backend_node_ips = [
    cidrhost("10.200.0.0/24", 10),  # Primary backend IP
    cidrhost("10.200.0.0/24", 11)   # Secondary backend IP
  ]

  # Labels
  deployment_labels = {
    application       = "mayascale"
    managed-by       = "terraform"
    deployment-name  = var.cluster_name
    performance-policy = var.performance_policy
    availability-strategy = local.active_policy.availability_strategy
    cost-tier        = local.active_policy.capacity_optimization
  }
}

# Virgin Node Replacement Detection Logic (DISABLED - Incomplete feature)
# data "google_compute_instances" "cluster_nodes" {
#   count = var.replacement_detection_enabled ? 1 : 0
#
#   # Use deployment_name if provided, otherwise fall back to cluster_name
#   filter = "name~'${local.cluster_name}-node[12]' AND labels.deployment-name='${coalesce(var.deployment_name, var.cluster_name)}'"
# }
#
# # Generate random suffix for replacement node uniqueness
# resource "random_id" "replacement_suffix" {
#   count       = var.enable_auto_replacement ? 1 : 0
#   byte_length = 4
# }
#
# locals {
#   # Virgin node replacement configuration
#   expected_nodes = ["${local.cluster_name}-node1", "${local.cluster_name}-node2"]
#   existing_nodes = var.replacement_detection_enabled && length(data.google_compute_instances.cluster_nodes) > 0 ? [
#     for instance in data.google_compute_instances.cluster_nodes[0].instances : instance.name
#   ] : []
#   missing_nodes = var.replacement_detection_enabled ? setsubtract(toset(local.expected_nodes), toset(local.existing_nodes)) : []
#
#   # Determine which specific nodes need replacement
#   need_node1_replacement = contains(local.missing_nodes, "${local.cluster_name}-node1")
#   need_node2_replacement = contains(local.missing_nodes, "${local.cluster_name}-node2")
#
#   # Surviving nodes for join operations
#   surviving_nodes = var.replacement_detection_enabled && length(data.google_compute_instances.cluster_nodes) > 0 ?
#     data.google_compute_instances.cluster_nodes[0].instances : []
# }

# Placement Policy for Optimal Zone Placement (zonal deployments only)
# Compact placement only works when both instances are in the SAME ZONE
# Regional (cross-zone) deployments cannot use compact placement

# Look up existing placement policy (if joining an existing placement group)
data "google_compute_resource_policy" "existing_placement_policy" {
  count   = local.active_policy.availability_strategy == "same-zone" && var.placement_policy_name != "" ? 1 : 0
  name    = var.placement_policy_name
  region  = var.region
  project = var.project_id
}

# Create new placement policy (if not joining an existing one)
resource "google_compute_resource_policy" "mayascale_placement_policy" {
  count       = local.active_policy.availability_strategy == "same-zone" && var.placement_policy_name == "" ? 1 : 0
  name        = "${local.cluster_name}-placement-policy"
  region      = var.region
  description = "Compact placement policy for MayaScale cluster - co-locates nodes on same/adjacent racks for minimal latency"

  group_placement_policy {
    vm_count    = 2 + var.client_count  # 2 storage nodes + optional client(s)
    collocation = "COLLOCATED"          # Co-locate on same or adjacent racks (reduces latency from 0.6-0.8ms to 0.1ms)
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Service Account for MayaScale Operations
resource "google_service_account" "mayascale_service_account" {
  account_id   = "${local.cluster_name}-sa"
  display_name = "MayaScale Cluster Service Account"
  description  = "Service account for MayaScale storage cluster operations"
}

# IAM bindings for HA failover cluster operations (same as MayaNAS)
resource "google_project_iam_member" "mayascale_compute_admin" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.mayascale_service_account.email}"
}

resource "google_project_iam_member" "mayascale_network_admin" {
  project = var.project_id
  role    = "roles/compute.networkAdmin"
  member  = "serviceAccount:${google_service_account.mayascale_service_account.email}"
}

resource "google_project_iam_member" "mayascale_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.mayascale_service_account.email}"
}

resource "google_project_iam_member" "mayascale_service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.mayascale_service_account.email}"
}

# Get default network for primary interface
data "google_compute_subnetwork" "default" {
  name   = "default"
  region = var.region
}

# NOTE: MTU 8896 configuration
# MTU is configured at runtime by startup script on each instance
# For optimal performance, manually set default network MTU before deployment:
#   gcloud compute networks update default --mtu=8896 --project=<project-id>
# Backend network MTU 8896 is configured in the network resource below

# Backend Network for Replication Traffic
resource "google_compute_network" "mayascale_backend" {
  name                    = "${local.cluster_name}-backend"
  auto_create_subnetworks = false
  mtu                     = 8896  # Enable jumbo frames for maximum throughput
  description            = "Dedicated backend network for MayaScale replication traffic"
}

resource "google_compute_subnetwork" "mayascale_backend_subnet" {
  name          = "${local.cluster_name}-backend-subnet"
  network       = google_compute_network.mayascale_backend.id
  ip_cidr_range = "10.200.0.0/24"
  region        = var.region
  description   = "Backend subnet for server-side replication"
}

# Firewall Rules
resource "google_compute_firewall" "mayascale_ssh" {
  name    = "${local.cluster_name}-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["mayascale-node"]
  description   = "Allow SSH access to MayaScale nodes"
}

# NVMe-oF firewall rule removed - clients are internal only
# Internal clients within same VPC/network can access storage nodes directly
# No public internet access needed for storage traffic

# Backend network internal communication rule
resource "google_compute_firewall" "mayascale_backend_internal" {
  name    = "${local.cluster_name}-backend-internal"
  network = google_compute_network.mayascale_backend.id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.200.0.0/24"]
  target_tags   = ["mayascale-node"]
  description   = "Allow all internal communication within backend network"

  # Ensure this firewall is destroyed before the network
  lifecycle {
    create_before_destroy = false
  }
}

# MayaScale Storage Nodes
resource "google_compute_instance" "mayascale_nodes" {
  count        = 2
  name         = "${local.cluster_name}-node${count.index + 1}"
  machine_type = local.selected_machine_type
  zone         = local.zone_strategy[count.index]

  # Request Intel Ice Lake CPUs for better network and CPU performance
  # Ice Lake: +18% IPC, better network offload vs Skylake
  # Only applies to n2-* instances (Intel), ignored for AMD/ARM
  min_cpu_platform = startswith(local.selected_machine_type, "n2-") ? "Intel Ice Lake" : null

  # Boot disk with MayaScale base image
  boot_disk {
    initialize_params {
      image = local.source_image_path
      size  = 20
      # C4, C3, C3D require hyperdisk-balanced (don't support pd-standard)
      type  = (
        startswith(local.selected_machine_type, "c4-") ||
        startswith(local.selected_machine_type, "c3-") ||
        startswith(local.selected_machine_type, "c3d-")
      ) ? "hyperdisk-balanced" : "pd-standard"
    }
    auto_delete = true
  }

  # Local NVMe SSDs for storage
  dynamic "scratch_disk" {
    for_each = range(local.active_policy.local_ssd_count)
    content {
      interface = "NVME"
    }
  }

  # Primary NIC: Client traffic (NVMe-oF 4420)
  # Use gVNIC with Tier_1 networking (up to 75 Gbps for 30+ vCPU machines)
  network_interface {
    network    = "default"
    nic_type   = "GVNIC"  # Required for Tier_1 networking and jumbo frames

    access_config {
      network_tier = "PREMIUM"
    }
  }

  # Enable Tier_1 networking for maximum bandwidth (only for 30+ vCPU machines)
  # n2-highcpu-32 with Tier_1: ~50 Gbps (vs 32 Gbps default)
  # n2-highcpu-64 with Tier_1: ~75 Gbps
  # Tier_1 requires 30+ vCPUs, bandwidth scales with vCPU count
  # Machines with <30 vCPUs will use default tier (TIER_DEFAULT)
  dynamic "network_performance_config" {
    for_each = local.enable_tier1_networking ? [1] : []
    content {
      total_egress_bandwidth_tier = "TIER_1"
    }
  }

  # Secondary NIC: Backend replication traffic (MTU 8896 jumbo frames)
  # Use gVNIC for high bandwidth replication
  network_interface {
    network    = google_compute_network.mayascale_backend.id
    subnetwork = google_compute_subnetwork.mayascale_backend_subnet.id
    network_ip = local.backend_node_ips[count.index]
    nic_type   = "GVNIC"  # Required for MTU 8896 jumbo frames support
    # No external IP for backend network
  }

  # Service account
  service_account {
    email  = google_service_account.mayascale_service_account.email
    scopes = ["cloud-platform"]
  }

  # Scheduling configuration
  # - Spot VMs: preemptible, automatic_restart=false, TERMINATE
  # - Collocated placement: automatic_restart=false, MIGRATE (placement policies don't support automatic restart)
  # - Standard: automatic_restart=true, MIGRATE (default behavior)
  dynamic "scheduling" {
    for_each = var.use_spot_vms || (local.active_policy.availability_strategy == "same-zone") ? [1] : []
    content {
      preemptible        = var.use_spot_vms ? true : false
      automatic_restart  = false  # Required: false for spot VMs AND collocated placement
      on_host_maintenance = var.use_spot_vms ? "TERMINATE" : "MIGRATE"
      provisioning_model = var.use_spot_vms ? "SPOT" : "STANDARD"
      instance_termination_action = var.use_spot_vms ? "STOP" : null
    }
  }

  tags = ["mayascale-node"]

  # Attach compact placement policy for zonal deployments only
  # Regional (cross-zone) deployments cannot use compact placement
  resource_policies = local.active_policy.availability_strategy == "same-zone" && local.placement_policy_id != "" ? [
    local.placement_policy_id
  ] : []

  # Metadata and startup script
  metadata = {
    ssh-keys = var.ssh_public_key != "" ? "mayascale:${var.ssh_public_key}" : ""
    cluster-name = var.cluster_name
    mayascale-cloud_user_password = random_password.mayascale_password.result
  }

  # Only primary node (node1) gets startup script - secondary joins via heartbeat
  # This prevents startup script text from polluting node2 metadata (which causes IPaliases bugs)
  metadata_startup_script = count.index == 0 ? templatefile("${path.module}/startup-cluster.sh.tpl", {
    cluster_name         = local.cluster_name
    deployment_type      = var.deployment_type
    node_role           = "node1"  # Always node1 since only primary gets script
    vip_address         = local.vip_address
    vip_address_2       = local.vip_address_2
    vip_cidr_range      = local.vip_cidr_range
    performance_policy  = var.performance_policy
    peer_zone          = local.zone_strategy[1]  # Always secondary zone
    resource_id        = random_integer.resource_id.result
    peer_resource_id   = random_integer.peer_resource_id.result
    nvme_count         = local.active_policy.local_ssd_count
    project_id         = var.project_id
    zone               = local.zone_strategy[0]  # Always primary zone
    primary_instance   = "${local.cluster_name}-node1"
    secondary_instance = "${local.cluster_name}-node2"
    node_count         = 2
    # Client export configuration
    client_nvme_port     = var.client_nvme_port
    client_iscsi_port    = var.client_iscsi_port
    client_protocol      = var.client_protocol
    client_exports_enabled = var.client_exports_enabled
    # Share configuration
    shares              = jsonencode(var.shares)
    # Startup wait configuration
    mayascale_startup_wait = var.mayascale_startup_wait != null ? tostring(var.mayascale_startup_wait) : ""
  }) : null  # No startup script for node2 (secondary)

  labels = merge(local.deployment_labels, {
    node-role = count.index == 0 ? "primary" : "secondary"
    node-index = tostring(count.index + 1)
  })

  depends_on = [
    google_compute_firewall.mayascale_ssh,
    google_compute_firewall.mayascale_backend_internal,
    google_service_account.mayascale_service_account,
    google_project_iam_member.mayascale_compute_admin,
    google_project_iam_member.mayascale_network_admin,
    google_project_iam_member.mayascale_storage_admin,
    google_project_iam_member.mayascale_service_account_user
    # Note: google_compute_resource_policy.mayascale_placement_policy removed
    # (conditional resource, implicit dependency through resource_policies attribute)
  ]
}

