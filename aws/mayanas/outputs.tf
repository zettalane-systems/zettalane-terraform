# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Standard outputs (consistent across all clouds)
output "node1_public_ip" {
  description = "Public IP of node 1"
  value       = var.assign_public_ip ? aws_instance.mayanas_primary.public_ip : null
}

output "node1_private_ip" {
  description = "Private IP of node 1"
  value       = aws_instance.mayanas_primary.private_ip
}

output "node1_name" {
  description = "Name of node 1"
  value       = aws_instance.mayanas_primary.tags["Name"]
}

output "node2_public_ip" {
  description = "Public IP of node 2 (HA only)"
  value       = local.is_ha_deployment && var.assign_public_ip ? aws_instance.mayanas_secondary[0].public_ip : null
}

output "node2_private_ip" {
  description = "Private IP of node 2 (HA only)"
  value       = local.is_ha_deployment ? aws_instance.mayanas_secondary[0].private_ip : null
}

output "node2_name" {
  description = "Name of node 2 (HA only)"
  value       = local.is_ha_deployment ? aws_instance.mayanas_secondary[0].tags["Name"] : null
}

output "vip_address" {
  description = "Virtual IP address"
  value       = local.vip_address
}

output "vip_address_2" {
  description = "Second VIP (active-active only)"
  value       = var.deployment_type == "active-active" ? local.vip_address_2 : null
}

# Storage Information
output "s3_bucket_names" {
  description = "Names of the S3 buckets created for data storage"
  value       = [for bucket in aws_s3_bucket.mayanas_data : bucket.id]
}

output "total_buckets" {
  description = "Total number of S3 buckets"
  value       = length(aws_s3_bucket.mayanas_data)
}

output "metadata_volume_ids" {
  description = "EBS volume IDs for metadata storage"
  value       = [for volume in aws_ebs_volume.mayanas_metadata : volume.id]
}

# Cluster Information
output "cluster_name" {
  description = "Name of the MayaNAS cluster"
  value       = local.effective_cluster_name
}

output "deployment_type" {
  description = "Type of deployment (active-passive or active-active)"
  value       = var.deployment_type
}

output "instance_type" {
  description = "EC2 instance type used for MayaNAS nodes"
  value       = var.instance_type
}

output "node_count" {
  description = "Number of nodes in the cluster"
  value       = local.node_count
}

# SSH Connection Commands
output "ssh_command_primary" {
  description = "SSH command to connect to the primary instance"
  value       = var.assign_public_ip ? "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayanas_primary.public_ip}" : "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayanas_primary.private_ip}"
}

output "ssh_command_secondary" {
  description = "SSH command to connect to the secondary instance (HA only)"
  value       = local.is_ha_deployment ? (var.assign_public_ip ? "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayanas_secondary[0].public_ip}" : "ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayanas_secondary[0].private_ip}") : null
}

# Web UI Access
output "web_ui_tunnel_primary" {
  description = "SSH tunnel command for Web UI access via primary node"
  value       = var.assign_public_ip ? "ssh -L 2020:localhost:2020 -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayanas_primary.public_ip}" : "ssh -L 2020:localhost:2020 -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayanas_primary.private_ip}"
}

output "web_ui_tunnel_secondary" {
  description = "SSH tunnel command for Web UI access via secondary node (HA only)"
  value       = local.is_ha_deployment ? (var.assign_public_ip ? "ssh -L 2020:localhost:2020 -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayanas_secondary[0].public_ip}" : "ssh -L 2020:localhost:2020 -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${aws_instance.mayanas_secondary[0].private_ip}") : null
}

# Network Configuration
output "vpc_id" {
  description = "VPC ID where MayaNAS is deployed"
  value       = local.selected_vpc_id
}

output "primary_subnet_id" {
  description = "Primary subnet ID (auto-discovered from availability zone)"
  value       = local.primary_subnet_id
}

output "secondary_subnet_id" {
  description = "Secondary subnet ID (same as primary for same-zone HA)"
  value       = local.secondary_subnet_id
}

output "security_group_id" {
  description = "Security group ID for MayaNAS cluster"
  value       = aws_security_group.mayanas_sg.id
}

# Deployment Info (structured, for automation/scripts)
output "deployment_info" {
  description = "Structured deployment information for automation"
  value = {
    cluster_name         = local.effective_cluster_name
    deployment_type      = var.deployment_type
    machine_type         = var.instance_type
    total_bucket_count   = length(aws_s3_bucket.mayanas_data)
    node_count           = local.node_count
    region               = data.aws_region.current.id
    primary_az           = local.primary_az
    secondary_az         = local.is_ha_deployment ? local.secondary_az : ""
    vip_address          = local.vip_address
    vip_address_2        = var.deployment_type == "active-active" ? local.vip_address_2 : ""
    s3_buckets           = local.bucket_names
    metadata_disks       = local.metadata_disk_names
    metadata_disk_gb     = local.metadata_disk_size_gb
    vpc_id               = local.selected_vpc_id
    security_group_id    = aws_security_group.mayanas_sg.id
  }
}

# Deployment Summary (pretty text, for humans)
output "deployment_summary" {
  description = "Human-readable deployment summary"
  value = <<-EOT
    
    🎯 MayaNAS ${upper(var.deployment_type)} Deployment Complete!
    
    📋 CLUSTER INFORMATION
    ├─ Name: ${local.effective_cluster_name}
    ├─ Type: ${upper(var.deployment_type)}
    ├─ Nodes: ${local.node_count}
    └─ Environment: ${var.environment}
    
    💻 INSTANCE DETAILS
    ├─ Primary: ${aws_instance.mayanas_primary.id} (${aws_instance.mayanas_primary.private_ip}${var.assign_public_ip ? ", public: ${aws_instance.mayanas_primary.public_ip}" : ""})
    ${local.is_ha_deployment ? "├─ Secondary: ${aws_instance.mayanas_secondary[0].id} (${aws_instance.mayanas_secondary[0].private_ip}${var.assign_public_ip ? ", public: ${aws_instance.mayanas_secondary[0].public_ip}" : ""})" : ""}
    └─ Instance Type: ${var.instance_type}
    
    🌐 NETWORK CONFIGURATION
    ├─ VPC: ${local.selected_vpc_id}
    ├─ Primary AZ: ${local.primary_az}
    ${local.is_ha_deployment ? "├─ Secondary AZ: ${local.secondary_az}" : ""}
    ├─ VIP: ${local.vip_address}
    ${var.deployment_type == "active-active" ? "├─ VIP2: ${local.vip_address_2}" : ""}
    └─ Security Group: ${aws_security_group.mayanas_sg.id}
    
    💾 STORAGE CONFIGURATION
    ├─ S3 Buckets: ${length(local.bucket_names)} (${join(", ", local.bucket_names)})
    ├─ Metadata Disks: ${length(local.metadata_disk_names)} x ${local.metadata_disk_size_gb}GB
    ├─ Storage Capacity: ${var.storage_size_gb}GB (logical)
    └─ Versioning: ${var.enable_s3_versioning ? "Enabled" : "Disabled"}
    
    🔐 ACCESS METHODS
    ├─ SSH Primary: ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${var.assign_public_ip ? aws_instance.mayanas_primary.public_ip : aws_instance.mayanas_primary.private_ip}
    ${local.is_ha_deployment ? "├─ SSH Secondary: ssh -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${var.assign_public_ip ? aws_instance.mayanas_secondary[0].public_ip : aws_instance.mayanas_secondary[0].private_ip}" : ""}
    ├─ Web UI Tunnel: ssh -L 2020:localhost:2020 -i ~/.ssh/${var.key_pair_name}.pem ec2-user@${var.assign_public_ip ? aws_instance.mayanas_primary.public_ip : aws_instance.mayanas_primary.private_ip}
    └─ Web UI Access: http://localhost:2020 (after tunnel is active)
    
    📝 NEXT STEPS
    1. Wait 5-10 minutes for initial setup to complete
    2. Create SSH tunnel using command above
    3. Access Web UI at http://localhost:2020
    4. Configure file shares and user access
    ${var.deployment_type == "active-passive" ? "5. Test HA failover using: mayanas-failover.sh" : ""}
    
    🔧 TROUBLESHOOTING
    - Check startup logs: tail -f /opt/mayastor/logs/mayanas-terraform-startup.log
    - Service status: systemctl status mayastor
    - Cluster status: mayacli cluster status
    
    EOT
}

# S3 Access Keys (if using access/secret key authentication)
output "s3_access_key_id" {
  description = "S3 access key ID (only when use_iam_role = false)"
  value       = var.use_iam_role ? null : aws_iam_access_key.mayanas_s3_key[0].id
}

output "s3_secret_access_key" {
  description = "S3 secret access key (only when use_iam_role = false)"
  value       = var.use_iam_role ? null : aws_iam_access_key.mayanas_s3_key[0].secret
  sensitive   = true
}

# Spot Pricing Analysis
output "spot_pricing_analysis" {
  description = "Spot pricing analysis for intelligent AZ selection"
  value = {
    spot_prices_by_az = var.use_spot_instance ? local.spot_prices : {}
    cheapest_az = var.use_spot_instance ? local.cheapest_az : null
    selected_az = local.selected_az
    selection_method = var.availability_zone != "" ? "user_specified" : (
      var.use_spot_instance ? "cheapest_spot_price" : "random_from_available"
    )
    use_spot_instance = var.use_spot_instance
  }
}

# Share Mount Instructions (for validate-performance.sh compatibility)
output "share_mount_instructions" {
  description = "Mount instructions for configured shares"
  value = {
    deployment_type = var.deployment_type
    shares = length(var.shares) > 0 ? (
      var.deployment_type == "active-active" ? {
        node1 = {
          for share in var.shares : share.name => {
            zpool       = "${local.effective_cluster_name}-pool-node1"
            vip         = local.vip_address
            nfs_mount   = contains(["nfs", "both"], share.export) ? "mount -t nfs ${local.vip_address}:/${local.effective_cluster_name}-pool-node1/${share.name} /mnt/${share.name}" : ""
            smb_share   = contains(["smb", "both"], share.export) ? "//${local.vip_address}/${local.effective_cluster_name}-pool-node1-${share.name}" : ""
          }
        }
        node2 = {
          for share in var.shares : share.name => {
            zpool       = "${local.effective_cluster_name}-pool-node2"
            vip         = local.vip_address_2
            nfs_mount   = contains(["nfs", "both"], share.export) ? "mount -t nfs ${local.vip_address_2}:/${local.effective_cluster_name}-pool-node2/${share.name} /mnt/${share.name}" : ""
            smb_share   = contains(["smb", "both"], share.export) ? "//${local.vip_address_2}/${local.effective_cluster_name}-pool-node2-${share.name}" : ""
          }
        }
      } : {
        node1 = {
          for share in var.shares : share.name => {
            zpool       = "${local.effective_cluster_name}-pool"
            server_ip   = var.deployment_type == "single" ? aws_instance.mayanas_primary.private_ip : local.vip_address
            nfs_mount   = contains(["nfs", "both"], share.export) ? "mount -t nfs ${var.deployment_type == "single" ? aws_instance.mayanas_primary.private_ip : local.vip_address}:/${local.effective_cluster_name}-pool/${share.name} /mnt/${share.name}" : ""
            smb_share   = contains(["smb", "both"], share.export) ? "//${var.deployment_type == "single" ? aws_instance.mayanas_primary.private_ip : local.vip_address}/${local.effective_cluster_name}-pool-${share.name}" : ""
          }
        }
      }
    ) : {}
  }
}
