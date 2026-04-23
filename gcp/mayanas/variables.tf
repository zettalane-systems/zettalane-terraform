# Project and Region Configuration
variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region for deployment"
  type        = string
  default     = "us-central1"
}

# Cluster Configuration
variable "cluster_name" {
  description = "Name of the MayaNAS cluster"
  type        = string
  default     = "mayanas"
  
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]*[a-z0-9])?$", var.cluster_name))
    error_message = "Cluster name must start with a letter, contain only lowercase letters, numbers, and hyphens, and end with a letter or number."
  }
}

variable "deployment_type" {
  description = "Type of deployment: single, active-passive, or active-active"
  type        = string
  default     = "active-active"
  
  validation {
    condition     = contains(["single", "active-passive", "active-active"], var.deployment_type)
    error_message = "Deployment type must be one of: single, active-passive, active-active."
  }
}

variable "environment" {
  description = "Environment label for resources"
  type        = string
  default     = "production"
}

# Compute Configuration
variable "machine_type" {
  description = "Machine type for MayaNAS instances"
  type        = string
  default     = "n1-standard-2"
}

# Image Configuration (GCP Marketplace metered image)
variable "source_image_project" {
  description = "Project containing the MayaNAS source image"
  type        = string
  default     = "zettalane-public"
}

variable "source_image_family" {
  description = "Image family for MayaNAS (uses latest image in family)"
  type        = string
  default     = "mayanas-enterprise"
}

variable "source_image" {
  description = "Specific image name (overrides family if set)"
  type        = string
  default     = ""
}

variable "boot_disk_size_gb" {
  description = "Size of the boot disk in GB"
  type        = number
  default     = 20
  
  validation {
    condition     = var.boot_disk_size_gb >= 10 && var.boot_disk_size_gb <= 2000
    error_message = "Boot disk size must be between 10 and 2000 GB."
  }
}

# Storage Configuration
variable "bucket_count" {
  description = "Number of GCS buckets to create per node for scaling capacity"
  type        = number
  default     = 1
  
  validation {
    condition     = var.bucket_count >= 1 && var.bucket_count <= 12
    error_message = "Bucket count must be between 1 and 12."
  }
}

variable "storage_pool_size" {
  description = "Size of each GCS bucket in GB"
  type        = number
  default     = 1000
  
  validation {
    condition     = var.storage_pool_size >= 10 && var.storage_pool_size <= 10000
    error_message = "Storage pool size must be between 10 and 10000 GB."
  }
}

variable "metadata_disk_count" {
  description = "Number of metadata disks to create per node"
  type        = number
  default     = 1
  
  validation {
    condition     = var.metadata_disk_count >= 1 && var.metadata_disk_count <= 4
    error_message = "Metadata disk count must be between 1 and 4."
  }
}

variable "metadata_disk_size_gb" {
  description = "Size of each metadata disk in GB"
  type        = number
  default     = 100
  
  validation {
    condition     = var.metadata_disk_size_gb >= 10 && var.metadata_disk_size_gb <= 2000
    error_message = "Metadata disk size must be between 10 and 2000 GB."
  }
}

variable "force_destroy_buckets" {
  description = "Allow terraform to destroy GCS buckets even when they contain objects (prevents accidental data loss when false)"
  type        = bool
  default     = false
}

variable "metadata_disk_type" {
  description = "Type of metadata disk. Use 'auto' for automatic selection based on machine type (N4→hyperdisk-balanced, others→pd-ssd). Manual options: pd-ssd, pd-balanced, pd-standard, pd-extreme, hyperdisk-balanced, hyperdisk-balanced-ha, hyperdisk-throughput, hyperdisk-extreme"
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "pd-ssd", "pd-balanced", "pd-standard", "pd-extreme", "hyperdisk-balanced", "hyperdisk-balanced-ha", "hyperdisk-throughput", "hyperdisk-extreme"], var.metadata_disk_type)
    error_message = "Metadata disk type must be one of: auto, pd-ssd, pd-balanced, pd-standard, pd-extreme, hyperdisk-balanced, hyperdisk-balanced-ha, hyperdisk-throughput, hyperdisk-extreme."
  }
}

# Zone Configuration
variable "zones" {
  description = "Zones for deployment. If empty, auto-selects based on multi_zone setting. Specify 1 zone for single-zone, 2 zones for multi-zone deployment."
  type        = list(string)
  default     = []  # Auto-select based on multi_zone
  
  validation {
    condition     = length(var.zones) <= 2
    error_message = "Basic module supports maximum 2 zones."
  }
}

variable "multi_zone" {
  description = "Enable multi-zone deployment with high availability. When true, creates regional metadata disks (replicated across zones) and deploys nodes in different zones. When false, uses zonal metadata disks and may deploy nodes in same zone. Regional disks cost 2x but provide zone-level fault tolerance."
  type        = bool
  default     = false
}

variable "vip_cidr_range" {
  description = "Manual override for VIP CIDR range (e.g., '10.100.5.0/24'). If not specified, automatically finds available range in 10.100.x.0/24 space."
  type        = string
  default     = ""
  
  validation {
    condition = var.vip_cidr_range == "" || can(cidrhost(var.vip_cidr_range, 0))
    error_message = "VIP CIDR range must be a valid CIDR notation (e.g., '10.100.5.0/24') or empty for automatic detection."
  }
}

# Network Configuration
variable "network_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "default"
}

variable "subnet_name" {
  description = "Name of the subnet (defaults to 'default' if not specified)"
  type        = string
  default     = ""
}

# Security Configuration
variable "ssh_public_key" {
  description = "SSH public key for instance access"
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_source_ranges" {
  description = "CIDR ranges allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Startup Script
variable "startup_script" {
  description = "Startup script for MayaNAS initialization"
  type        = string
  default     = ""
}

variable "mayanas_startup_wait" {
  description = "Time in seconds to wait for MayaNAS startup process to complete (null = use default 90s, 0 = no wait)"
  type        = number
  nullable    = true
  default     = null

  validation {
    condition     = var.mayanas_startup_wait == null ? true : var.mayanas_startup_wait >= 0
    error_message = "MayaNAS startup wait must be null or 0 or greater."
  }
}

# Share Configuration
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

  validation {
    condition = alltrue([
      for share in var.shares : can(regex("^[a-zA-Z0-9_-]+$", share.name))
    ])
    error_message = "Share names must contain only alphanumeric characters, hyphens, and underscores."
  }
  
  validation {
    condition = alltrue([
      for share in var.shares : contains(["nfs", "nfs3", "smb", "multi"], share.export)
    ])
    error_message = "Share export type must be 'nfs', 'nfs3', 'smb', or 'multi'."
  }
  
  validation {
    condition = alltrue([
      for share in var.shares : contains(["512K", "1024K", "2048K", "4096K"], share.recordsize)
    ])
    error_message = "Record size must be one of: 512K, 1024K, 2048K, 4096K."
  }

  validation {
    condition = alltrue([
      for share in var.shares : share.smb_profile == "" || contains(["posix", "windows", "multiprotocol"], share.smb_profile)
    ])
    error_message = "SMB profile must be empty or one of: posix, windows, multiprotocol."
  }
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

variable "boot_disk_type" {
  description = "Boot disk type for MayaNAS instances. Use 'auto' for automatic selection based on machine type (N4→hyperdisk-balanced, others→pd-balanced). Manual options: pd-standard, pd-balanced, pd-ssd, hyperdisk-balanced, hyperdisk-balanced-ha, hyperdisk-throughput"
  type        = string
  default     = "auto"

  validation {
    condition = contains(["auto", "pd-standard", "pd-balanced", "pd-ssd", "hyperdisk-balanced", "hyperdisk-balanced-ha", "hyperdisk-throughput"], var.boot_disk_type)
    error_message = "Boot disk type must be one of: auto, pd-standard, pd-balanced, pd-ssd, hyperdisk-balanced, hyperdisk-balanced-ha, hyperdisk-throughput."
  }
}

