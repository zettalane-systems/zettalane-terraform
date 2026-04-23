# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# MayaScale GCP Marketplace Variables
# Simplified interface for marketplace deployment

variable "project_id" {
  description = "The ID of the project in which to provision resources."
  type        = string
}

# Cluster Configuration
variable "cluster_name" {
  description = "Name for the MayaScale cluster (used for resource naming)"
  type        = string
  default     = "mayascale"
}

variable "source_image_project" {
  description = "Project containing the MayaScale source image"
  type        = string
  default     = "zettalane-public"
}

variable "source_image_family" {
  description = "Image family for MayaScale (uses latest image in family)"
  type        = string
  default     = "mayascale-enterprise"
}

variable "source_image" {
  description = "Specific image name (overrides family if set)"
  type        = string
  default     = ""
}

# Performance Policy (Simplified for Marketplace)
variable "performance_policy" {
  description = "Performance and availability policy for storage cluster"
  type        = string
  default     = "regional-high-performance"

  validation {
    condition = contains([
      # Marketplace tiers (shown to users) - AGGREGATE IOPS across 2-node HA cluster
      "regional-ultra-performance",     # 1.2M read / 630K write, n2-highcpu-64, 16 NVMe, 75 Gbps Tier_1
      "regional-high-performance",      # 900K read / 315K write, n2-highcpu-32, 8 NVMe, 50 Gbps Tier_1
      "regional-medium-performance",    # 700K read / 180K write, n2-highcpu-16, 4 NVMe, 32 Gbps
      "regional-standard-performance",  # 380K read / 120K write, n2-highcpu-8, 2 NVMe, 16 Gbps
      "regional-basic-performance",     # 100K read / 60K write, n2-highcpu-4, 1 NVMe, 10 Gbps
      "zonal-ultra-performance",        # 1.4M read / 700K write, n2-highcpu-64, 16 NVMe, 75 Gbps Tier_1
      "zonal-high-performance",         # 900K read / 350K write, n2-highcpu-32, 8 NVMe, 50 Gbps Tier_1
      "zonal-medium-performance",       # 700K read / 200K write, n2-highcpu-16, 4 NVMe, 32 Gbps
      "zonal-standard-performance",     # 380K read / 130K write, n2-highcpu-8, 2 NVMe, 16 Gbps
      "zonal-basic-performance"         # 100K read / 75K write, n2-highcpu-4, 1 NVMe, 10 Gbps
    ], var.performance_policy)
    error_message = "Performance policy must be one of the predefined options."
  }
}

# Location Configuration
variable "zone" {
  description = "The zone for the solution to be deployed"
  type        = string
  default     = "us-central1-a"
}

variable "region" {
  description = "The region for the deployment"
  type        = string
  default     = "us-central1"
}

# Optional Overrides
variable "machine_type" {
  description = "Machine type for storage nodes (auto-selected based on performance policy if not specified)"
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
  default     = ""
}

variable "vip_cidr_range" {
  description = "CIDR range for VIP allocation"
  type        = string
  default     = ""
}

variable "use_spot_vms" {
  description = "Enable Spot VMs for cost savings (recommended for testing/development)"
  type        = bool
  default     = false
}

variable "assign_public_ip" {
  description = "Assign public IPs to instances (set false for private-only deployment)"
  type        = bool
  default     = false
}

# Client Access Configuration
variable "client_nvme_port" {
  description = "Base port for client NVMe-oF connections (data-node-1 uses this port, data-node-2 uses +2, etc.)"
  type        = number
  default     = 4420
}

variable "client_iscsi_port" {
  description = "Base port for client iSCSI connections"
  type        = number
  default     = 3260
}

variable "client_protocol" {
  description = "Protocol for client volume access"
  type        = string
  default     = "nvme"

  validation {
    condition     = contains(["nvme", "iscsi", "both"], var.client_protocol)
    error_message = "Protocol must be nvme, iscsi, or both."
  }
}

variable "client_access_control" {
  description = "Client access control list (IPs or subnets allowed to connect)"
  type        = list(string)
  default     = ["0.0.0.0/0"]  # Allow all by default
}

variable "client_exports_enabled" {
  description = "Enable automatic client volume exports for data-node-X volumes"
  type        = bool
  default     = true
}

# Virgin Node Replacement Configuration
variable "enable_auto_replacement" {
  description = "Enable automatic replacement of failed nodes"
  type        = bool
  default     = true
}

variable "replacement_detection_enabled" {
  description = "Enable detection of missing cluster nodes"
  type        = bool
  default     = true
}

variable "deployment_name" {
  description = "Deployment name for filtering instances (defaults to cluster_name)"
  type        = string
  default     = ""
}

# Placement Policy Configuration
variable "client_count" {
  description = "Number of client VMs to reserve in placement policy (0 for storage-only, 1 for co-located client). Set to 1 when deploying client concurrently for optimal latency."
  type        = number
  default     = 0

  validation {
    condition     = var.client_count >= 0 && var.client_count <= 5
    error_message = "Client count must be between 0 and 5."
  }
}

variable "placement_policy_name" {
  description = "Name of existing placement policy to join (leave empty to create new placement policy)"
  type        = string
  default     = ""
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
