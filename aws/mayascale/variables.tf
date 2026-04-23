# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# AWS MayaScale Terraform Module - Variables
# Performance-tier based deployment for AWS EC2 with instance storage (i3, i3en, i4i families)

# Marketplace Configuration
variable "mayascale_product_code" {
  description = "AWS Marketplace product code for MayaScale (used for auto AMI lookup)"
  type        = string
  default     = "PLACEHOLDER_MAYASCALE_PRODUCT_CODE"  # TODO: Update with actual product code before release
}

# Core Configuration
variable "region" {
  description = "AWS region for deployment (e.g., us-east-1, us-west-2)"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the MayaScale cluster (auto-generated if not specified)"
  type        = string
  default     = ""
}

variable "performance_policy" {
  description = "Performance tier policy (determines instance type, IOPS targets, capacity)"
  type        = string
  default     = "zonal-medium-performance"

  validation {
    condition = contains([
      "zonal-basic-performance",
      "zonal-standard-performance",
      "zonal-medium-performance",
      "zonal-high-performance",
      "zonal-ultra-performance",
      "regional-basic-performance",
      "regional-standard-performance",
      "regional-medium-performance",
      "regional-high-performance",
      "regional-ultra-performance"
    ], var.performance_policy)
    error_message = "Performance policy must be one of: zonal-* (same-AZ) or regional-* (cross-AZ HA) with basic/standard/medium/high/ultra tier"
  }
}

# Network Configuration
variable "availability_zone" {
  description = "Primary availability zone for deployment (defaults to first available AZ)"
  type        = string
  default     = ""
}

variable "availability_zone_secondary" {
  description = "Secondary availability zone for multi-AZ deployments (defaults to second available AZ)"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID for deployment (creates default VPC if not specified)"
  type        = string
  default     = ""
}

variable "subnet_id_primary" {
  description = "Subnet ID for primary node (auto-created if not specified)"
  type        = string
  default     = ""
}

variable "subnet_id_secondary" {
  description = "Subnet ID for secondary node in multi-AZ deployments (auto-created if not specified)"
  type        = string
  default     = ""
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access (e.g., ['10.0.0.0/8'])"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

# EC2 Configuration
variable "key_pair_name" {
  description = "EC2 Key Pair name for SSH access (required)"
  type        = string
}

variable "ami_id" {
  description = "MayaScale AMI ID (auto-detected from AWS Marketplace if not specified)"
  type        = string
  default     = ""
}

variable "use_spot_instances" {
  description = "Use EC2 Spot instances for cost savings (50-70% reduction)"
  type        = bool
  default     = true
}

variable "assign_public_ip" {
  description = "Assign public IPs to instances (set false for private-only deployment)"
  type        = bool
  default     = false
}

variable "instance_type_override" {
  description = "Override instance type from performance policy (for custom configurations)"
  type        = string
  default     = ""

  validation {
    condition     = var.instance_type_override == "" || can(regex("^(i3|i3en|i4i)\\.(large|xlarge|[0-9]+xlarge|metal)$", var.instance_type_override))
    error_message = "Instance type override must be empty or a valid storage-optimized instance (i3, i3en, i4i families)"
  }
}

# Advanced Options
variable "enable_placement_group" {
  description = "Enable placement group for same-AZ deployments (lower latency ~100µs improvement)"
  type        = bool
  default     = true
}

# Note: ENA (Elastic Network Adapter) is automatically enabled when both AMI and instance type support it.
# All our instance types (i3.large, i3en.*, i4i.*) support ENA by default - no explicit configuration needed.
# EFA (Elastic Fabric Adapter) is NOT supported on storage-optimized instances (i3, i3en, i4i).

variable "enable_monitoring" {
  description = "Enable detailed CloudWatch monitoring"
  type        = bool
  default     = true
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 100
}

variable "root_volume_type" {
  description = "Root EBS volume type (gp3, gp2, io2)"
  type        = string
  default     = "gp3"
}

# Tags
variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# HA Configuration
variable "enable_auto_failover" {
  description = "Enable automatic failover for multi-AZ deployments"
  type        = bool
  default     = true
}

variable "health_check_interval_seconds" {
  description = "Interval for health checks in seconds"
  type        = number
  default     = 30
}

# Performance Tuning
variable "nvme_io_scheduler" {
  description = "I/O scheduler for NVMe devices (none, mq-deadline, kyber)"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "mq-deadline", "kyber"], var.nvme_io_scheduler)
    error_message = "I/O scheduler must be one of: none, mq-deadline, kyber"
  }
}

variable "enable_nvme_optimization" {
  description = "Enable NVMe device optimization (queue depth, polling)"
  type        = bool
  default     = true
}

# Client Access Configuration
variable "client_protocol" {
  description = "Client access protocol (nvme-tcp, iscsi)"
  type        = string
  default     = "nvme-tcp"

  validation {
    condition     = contains(["nvme-tcp", "iscsi"], var.client_protocol)
    error_message = "Client protocol must be either 'nvme-tcp' or 'iscsi'"
  }
}

variable "client_exports_enabled" {
  description = "Enable client volume exports for data access"
  type        = bool
  default     = true
}

variable "client_nvme_port" {
  description = "Starting port for NVMe-oF client connections"
  type        = number
  default     = 4420

  validation {
    condition     = var.client_nvme_port >= 1024 && var.client_nvme_port <= 65520
    error_message = "NVMe port must be between 1024 and 65520 (need room for multiple volumes)"
  }
}

variable "client_iscsi_port" {
  description = "Port for iSCSI client connections"
  type        = number
  default     = 3260

  validation {
    condition     = var.client_iscsi_port >= 1024 && var.client_iscsi_port <= 65535
    error_message = "iSCSI port must be between 1024 and 65535"
  }
}

variable "client_access_control" {
  description = "CIDR blocks allowed for client data access"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "deployment_type" {
  description = "Deployment architecture: 'active-active' (MD RAID + ZFS) or 'zfs-active-active' (ZFS mirror vdevs, FSx for OpenZFS equivalent)"
  type        = string
  default     = "active-active"

  validation {
    condition     = contains(["active-active", "zfs-active-active"], var.deployment_type)
    error_message = "deployment_type must be either 'active-active' or 'zfs-active-active'"
  }
}

# NFS/SMB Share Configuration
variable "shares" {
  description = "List of shares to create with protocol support (NFS, SMB, or both)"
  type = list(object({
    name         = string
    recordsize   = string
    export       = string  # "nfs", "nfs3", "smb", or "multi"
    nfs_options  = optional(string, "")
    smb_options  = optional(string, "")
    smb_profile  = optional(string, "")  # "posix", "windows", or "multiprotocol"
    smb_user     = optional(string, "")
    smb_password = optional(string, "")
    smb_uid      = optional(string, "")
    smb_group    = optional(string, "")
    smb_gid      = optional(string, "")
  }))
  default = []
}

# System Startup Configuration
variable "mayascale_startup_wait" {
  description = "Time in seconds to wait for MayaScale startup process to complete (null = no wait/no export, number = wait N seconds)"
  type        = number
  nullable    = true
  default     = null

  validation {
    condition     = var.mayascale_startup_wait == null ? true : var.mayascale_startup_wait >= 0
    error_message = "MayaScale startup wait must be null or 0 or greater."
  }
}
