# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# AWS MayaScale Terraform Module - Outputs

# Deployment Summary
output "cluster_name" {
  description = "Name of the deployed MayaScale cluster"
  value       = local.cluster_name
}

output "deployment_id" {
  description = "Unique deployment identifier"
  value       = random_id.suffix.hex
}

# Performance Configuration
output "performance_policy" {
  description = "Selected performance policy tier"
  value       = var.performance_policy
}

output "target_write_iops" {
  description = "Target write IOPS for this deployment"
  value       = local.selected_policy.target_write_iops
}

output "target_read_iops" {
  description = "Target read IOPS for this deployment"
  value       = local.selected_policy.target_read_iops
}

output "target_latency_ms" {
  description = "Target latency in milliseconds"
  value       = local.selected_policy.target_write_latency / 1000
}

output "target_bandwidth_mbps" {
  description = "Target bandwidth in MB/s"
  value       = local.selected_policy.target_bandwidth_mbps
}

# Instance Configuration
output "instance_type" {
  description = "EC2 instance type used for deployment"
  value       = local.selected_instance_type
}

output "nvme_device_count" {
  description = "Number of NVMe devices per instance"
  value       = local.selected_policy.nvme_device_count
}

output "nvme_total_capacity_gb" {
  description = "Total NVMe capacity across cluster in GB"
  value       = local.selected_policy.nvme_capacity_gb
}

# Network Configuration - CRITICAL FOR VALIDATE-MAYASCALE.SH
output "vip_addresses" {
  description = "Virtual IP addresses for client connections"
  value = {
    primary_vip   = local.vip_address
    secondary_vip = local.node_count > 1 ? local.vip_address_2 : ""
    active_vips   = local.node_count > 1 ? (local.selected_policy.nvme_device_count > 1 ? [local.vip_address, local.vip_address_2] : [local.vip_address]) : [local.csi_node1_vip]
  }
}

# Backward compatibility
output "vip_address" {
  description = "Primary virtual IP address for client connections"
  value       = local.vip_address
}

# Client Volumes - CRITICAL FOR VALIDATE-MAYASCALE.SH
output "client_volumes" {
  description = "Client volume NQN endpoints for data access"
  value = var.client_exports_enabled ? {
    for i in range(local.selected_policy.nvme_device_count) : "data-node-${i + 1}" => {
      nqn          = "nqn.2019-05.com.zettalane:mayascale-${(i + 1) % 2 == 1 ? random_integer.resource_id.result : random_integer.peer_resource_id.result}-vol-data-node-${i + 1}"
      port         = var.client_nvme_port + i
      vip_endpoint = "${i % 2 == 0 ? local.vip_address : local.vip_address_2}:${var.client_nvme_port + i}"
      vip_address  = i % 2 == 0 ? local.vip_address : local.vip_address_2
      size_gb      = local.selected_policy.nvme_device_count > 1 ? 375 : local.selected_policy.nvme_capacity_gb
      protocol     = var.client_protocol
      cluster_id   = (i + 1) % 2 == 1 ? random_integer.resource_id.result : random_integer.peer_resource_id.result
    }
  } : {}
}

# Instance Details
output "node1_instance_id" {
  description = "Node1 EC2 instance ID"
  value       = aws_instance.mayascale_node1.id
}

output "node2_instance_id" {
  description = "Node2 EC2 instance ID (empty on single-node)"
  value       = local.node_count > 1 ? aws_instance.mayascale_node2[0].id : ""
}

output "node1_public_ip" {
  description = "Node1 public IP address"
  value       = var.assign_public_ip ? aws_instance.mayascale_node1.public_ip : null
}

output "node1_private_ip" {
  description = "Node1 private IP address"
  value       = aws_instance.mayascale_node1.private_ip
}

output "node1_name" {
  description = "Node1 instance name"
  value       = aws_instance.mayascale_node1.tags["Name"]
}

output "node2_public_ip" {
  description = "Node2 public IP address (null on single-node)"
  value       = local.node_count > 1 && var.assign_public_ip ? aws_instance.mayascale_node2[0].public_ip : null
}

output "node2_private_ip" {
  description = "Node2 private IP address (empty on single-node)"
  value       = local.node_count > 1 ? aws_instance.mayascale_node2[0].private_ip : ""
}

output "node2_name" {
  description = "Node2 instance name (empty on single-node)"
  value       = local.node_count > 1 ? aws_instance.mayascale_node2[0].tags["Name"] : ""
}

output "vip1_address" {
  description = "Primary VIP address"
  value       = local.vip_address
}

output "vip2_address" {
  description = "Secondary VIP address (empty on single-node)"
  value       = local.node_count > 1 ? local.vip_address_2 : ""
}

# Availability Zones
output "primary_availability_zone" {
  description = "Primary availability zone"
  value       = local.node1_az
}

output "secondary_availability_zone" {
  description = "Secondary availability zone (same as primary for same-AZ deployments)"
  value       = local.node2_az
}

output "availability_strategy" {
  description = "Availability strategy (same-az or cross-az)"
  value       = local.selected_policy.availability_strategy
}

# Capacity Planning
output "capacity_optimization" {
  description = "Capacity optimization strategy"
  value       = local.selected_policy.capacity_optimization
}

# Validation Status
output "validation_status" {
  description = "Performance validation status"
  value       = var.performance_policy == "zonal-ultra-performance" || var.performance_policy == "regional-ultra-performance" ? "✅ VALIDATED - i3en.12xlarge tested Nov 1, 2025 (528K write / 1.35M read)" : var.performance_policy == "zonal-high-performance" || var.performance_policy == "regional-high-performance" ? "✅ VALIDATED - i3en.6xlarge performance confirmed" : var.performance_policy == "zonal-standard" || var.performance_policy == "regional-standard" ? "✅ VALIDATED - i3en.2xlarge performance confirmed" : var.performance_policy == "zonal-basic" || var.performance_policy == "regional-basic" ? "✅ VALIDATED - i4i.xlarge performance confirmed" : "ESTIMATED - Targets based on validated testing"
}

# SSH Access
output "ssh_commands" {
  description = "SSH commands to connect to nodes"
  value = {
    node1 = var.assign_public_ip ? "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayascale_node1.public_ip}" : "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayascale_node1.private_ip}"
    node2 = local.node_count <= 1 ? "" : (var.assign_public_ip ? "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayascale_node2[0].public_ip}" : "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayascale_node2[0].private_ip}")
  }
}

# Cost Information
output "cost_optimization_tips" {
  description = "Tips for cost optimization"
  value = {
    spot_instances        = "Enable use_spot_instances=true for 50-70% cost savings"
    right_sizing          = "Choose tier based on actual IOPS needs, not just capacity"
    single_az_vs_multi_az = "Single-AZ deployment costs ~50% of Multi-AZ"
    instance_family       = "i3 < i3en (cost increases with capacity)"
  }
}

# Next Steps
output "next_steps" {
  description = "Next steps for deployment validation"
  value = {
    step1 = var.assign_public_ip ? "SSH to node1: ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayascale_node1.public_ip}" : "SSH to node1: ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayascale_node1.private_ip}"
    step2 = "Monitor startup: tail -f /var/log/cloud-init-output.log"
    step3 = "Deploy client using validate-mayascale.sh with --cloud aws"
    step4 = "Run performance tests to validate IOPS targets"
    step5 = "Update targets in main.tf based on real AWS measurements"
  }
}

# Placement group for client co-location (zonal on-demand deployments only)
# AWS limitation: Spot instances with interruption_behavior='stop' cannot use placement groups
output "placement_group_name" {
  description = "Placement group name for client co-location (empty if regional or spot with stop behavior)"
  value       = (local.selected_policy.availability_strategy == "same-az" && !var.use_spot_instances) ? aws_placement_group.mayascale_pg[0].name : ""
}

# Alias for script compatibility
output "availability_zone" {
  description = "Primary availability zone (alias for primary_availability_zone)"
  value       = local.node1_az
}

# Deployment Summary - CRITICAL FOR VALIDATE-MAYASCALE.SH AND ANALYZE SCRIPTS
# Standardized across all cloud providers (GCP/AWS/Azure)
output "deployment_summary" {
  description = "Complete deployment summary for validation scripts (standardized schema)"
  value = {
    cloud_provider        = "aws"
    cluster_name          = local.cluster_name
    deployment_id         = random_id.suffix.hex
    performance_policy    = var.performance_policy
    availability_strategy = local.selected_policy.availability_strategy

    instance_type    = local.selected_instance_type
    vcpus            = lookup(local.vcpu_map, local.selected_instance_type, 0)
    nvme_capacity_gb = local.selected_policy.nvme_capacity_gb
    ssd_count        = local.selected_policy.nvme_device_count

    target_write_iops       = local.selected_policy.target_write_iops
    target_read_iops        = local.selected_policy.target_read_iops
    target_write_latency_us = local.selected_policy.target_write_latency
    target_bandwidth_MBps   = local.selected_policy.target_bandwidth_mbps

    zone_primary   = local.node1_az
    zone_secondary = local.node2_az
    region         = var.region

    cost_tier        = local.selected_policy.capacity_optimization
    dual_nic_enabled = false
  }
}

# CSI backend wiring (for the ZettaLane CSI driver, provisioner csi-mayascale.zettalane.com).
# Feed straight into the driver config Secret / Helm values. Use with
# deployment_type = "vg-active-active": the driver carves per-PVC LVs from the per-node
# CSI VG and exports them as per-volume NVMe-oF subsystems (portalgroup=auto). Mirrors the
# mayanas csi_backend shape so both products configure the driver identically.
output "csi_backend" {
  description = "Connection + pool map for the csi-mayascale driver (cluster VIP list named for the driver, pool -> {clusterid, vip}). Pools branch on deployment_type: vg-active-active -> per-node VG + thinpool; zfs-active-active -> per-node zpool data-pool-{1,2}."
  value = {
    # options.driver -- selects the product/instance (block backend, RWO).
    driver = "mayascale"
    # Control-plane endpoint: 2-node = both VIPs; single-node has no VIP -> node1 private IP.
    mayascale = local.node_count > 1 ? join(",", [local.vip_address, local.vip_address_2]) : local.csi_node1_vip

    # CSI pools, created by cluster_mayascale.sh (2-node) / standalone_mayascale.sh (single);
    # the driver discovers each pool's kind (V_VG / V_THINPOOL / V_ZPOOL) and routes accordingly.
    # Branch on substrate (zfs* -> zpool data-pool-N; else VG + thinpool) and node count:
    #   vg-active-active  -> thick VG <cluster>-vg-node{1,2} (driver carves V_FLEX LVs) AND a
    #                        thin pool <cluster>-vgpool-node{1,2} inside it (thin LVs).
    #   zfs-active-active -> one zpool per node, data-pool-{1,2} (driver carves zvols/datasets).
    # Single-node uses clusterid 0 (a local, non-failover resource) + node1 IP.
    # tomap() so all ternary branches share a type (different key counts otherwise).
    pools = startswith(var.deployment_type, "zfs") ? (
      local.node_count > 1 ? tomap({
        "data-pool-1" = { clusterid = random_integer.resource_id.result, vip = local.csi_node1_vip }
        "data-pool-2" = { clusterid = random_integer.peer_resource_id.result, vip = local.vip_address_2 }
        }) : tomap({
        "data-pool-1" = { clusterid = 0, vip = local.csi_node1_vip }
      })
      ) : (
      local.node_count > 1 ? tomap({
        "${local.cluster_name}-vg-node1"     = { clusterid = random_integer.resource_id.result, vip = local.csi_node1_vip }
        "${local.cluster_name}-vg-node2"     = { clusterid = random_integer.peer_resource_id.result, vip = local.vip_address_2 }
        "${local.cluster_name}-vgpool-node1" = { clusterid = random_integer.resource_id.result, vip = local.csi_node1_vip }
        "${local.cluster_name}-vgpool-node2" = { clusterid = random_integer.peer_resource_id.result, vip = local.vip_address_2 }
        }) : tomap({
        "${local.cluster_name}-vg-node1"     = { clusterid = 0, vip = local.csi_node1_vip }
        "${local.cluster_name}-vgpool-node1" = { clusterid = 0, vip = local.csi_node1_vip }
      })
    )

    # zone -> data VIP, for the driver's zone-aware topology (zone_cluster_map).
    # AWS AZ names (topology.kubernetes.io/zone on EKS nodes) map to the owning node's VIP.
    zone_cluster_map = local.node_count > 1 ? {
      (local.node1_az) = local.vip_address
      (local.node2_az) = local.vip_address_2
      } : {
      (local.node1_az) = local.csi_node1_vip
    }
  }
}

# Object storage (objbacker cold tier) -- null unless bucket_count > 0.
output "buckets_by_node" {
  description = "Cold-tier buckets split per node: first bucket_count are node1's, the rest node2's, so each node builds its own objbacker pool"
  value = local.object_tier_enabled ? {
    node1 = slice(local.bucket_names, 0, var.bucket_count)
    node2 = slice(local.bucket_names, var.bucket_count, local.total_bucket_count)
  } : null
}

# Module Metadata
output "module_version" {
  description = "Module version and source"
  value = {
    version      = "1.0.0"
    based_on     = "AWS validated performance testing (Nov 2025)"
    last_updated = "2025-11-02"
    source       = "terraform-aws-mayascale"
  }
}

# Deployment Info - Structured information for automation scripts
output "deployment_info" {
  description = "Structured deployment information for automation scripts"
  value = {
    cluster_name      = local.cluster_name
    node_count        = local.node_count
    region            = var.region
    primary_az        = local.node1_az
    secondary_az      = local.node_count > 1 ? local.node2_az : ""
    machine_type      = local.selected_instance_type
    node1_name        = aws_instance.mayascale_node1.id
    node1_az          = aws_instance.mayascale_node1.availability_zone
    node1_external_ip = var.assign_public_ip ? aws_instance.mayascale_node1.public_ip : null
    node1_internal_ip = aws_instance.mayascale_node1.private_ip
    node2_name        = local.node_count > 1 ? aws_instance.mayascale_node2[0].id : ""
    node2_az          = local.node_count > 1 ? aws_instance.mayascale_node2[0].availability_zone : ""
    node2_external_ip = local.node_count > 1 && var.assign_public_ip ? aws_instance.mayascale_node2[0].public_ip : null
    node2_internal_ip = local.node_count > 1 ? aws_instance.mayascale_node2[0].private_ip : ""
    vip_primary       = local.vip_address
    vip_secondary     = local.node_count > 1 ? local.vip_address_2 : ""
    total_nvme_count  = local.selected_policy.nvme_device_count * local.node_count
    total_capacity_gb = local.selected_policy.nvme_capacity_gb
  }
}
