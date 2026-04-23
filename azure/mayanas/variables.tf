# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Required Variables
variable "vm_image_id" {
  description = "MayaNAS VM Image ID for deployment (auto-detected by region if empty)"
  type        = string
  default     = ""
}

variable "resource_group_name" {
  description = "Azure Resource Group name (required)"
  type        = string
}

variable "location" {
  description = "Azure region/location for MayaNAS deployment (empty = use Azure CLI default)"
  type        = string
  default     = ""
}

variable "multi_zone" {
  description = "Deploy across multiple availability zones for HA (auto-selects zones if availability_zones is empty)"
  type        = bool
  default     = false
}

variable "availability_zones" {
  description = "Azure availability zones for HA deployment (will auto-select 2 zones if multi_zone=true and this is empty)"
  type        = list(string)
  default     = []
}

variable "ssh_public_key" {
  description = "SSH public key content for VM access (full key content)"
  type        = string
  default     = ""
}

variable "ssh_key_vault_id" {
  description = "Optional: Azure Key Vault secret ID containing SSH public key (alternative to ssh_public_key)"
  type        = string
  default     = ""
}

variable "ssh_key_resource_id" {
  description = "Optional: Azure SSH Public Key resource ID for Azure-managed key pairs (alternative to ssh_public_key)"
  type        = string
  default     = ""
}

# Deployment Configuration
variable "cluster_name" {
  description = "Name of the MayaNAS deployment (optional - auto-generated if not provided)"
  type        = string
  default     = ""
  
  validation {
    condition     = var.cluster_name == "" || can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.cluster_name))
    error_message = "Cluster name must be 3-63 characters, start and end with alphanumeric, and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "deployment_type" {
  description = "Type of MayaNAS deployment"
  type        = string
  default     = "active-passive"
  
  validation {
    condition     = contains(["single", "active-passive", "active-active"], var.deployment_type)
    error_message = "Deployment type must be one of: single, active-passive, active-active."
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod, etc.)"
  type        = string
  default     = "prod"
  
  validation {
    condition     = contains(["dev", "staging", "prod", "test"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod, test."
  }
}

# Azure VIP Configuration (Dual Mechanism Support)
variable "vip_mechanism" {
  description = "VIP mechanism: load-balancer or custom-route"
  type        = string
  default     = "custom-route"
  
  validation {
    condition     = contains(["load-balancer", "custom-route"], var.vip_mechanism)
    error_message = "VIP mechanism must be load-balancer or custom-route."
  }
}

variable "vip_address" {
  description = "Virtual IP address for HA deployments (auto-generated if empty)"
  type        = string
  default     = ""
}

variable "vip_address_2" {
  description = "Second Virtual IP address for active-active deployments (auto-generated if empty)"
  type        = string
  default     = ""
}

# Network Configuration
variable "vnet_name" {
  description = "Virtual Network name (will auto-detect default VNet if empty)"
  type        = string
  default     = ""
}

variable "subnet_name" {
  description = "Subnet name (will auto-detect default subnet if empty)"
  type        = string
  default     = ""
}

variable "vnet_address_space" {
  description = "Virtual Network address space"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "subnet_address_prefixes" {
  description = "Subnet address prefixes"
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Compute Configuration
variable "vm_size" {
  description = "Azure VM size"
  type        = string
  default     = "Standard_D4s_v3"  # 4 vCPU, 16GB RAM, Accelerated Networking
}

variable "os_disk_type" {
  description = "OS disk type"
  type        = string
  default     = "Premium_LRS"
  
  validation {
    condition     = contains(["Standard_LRS", "Premium_LRS", "StandardSSD_LRS"], var.os_disk_type)
    error_message = "OS disk type must be Standard_LRS, Premium_LRS, or StandardSSD_LRS."
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 30
  
  validation {
    condition     = var.os_disk_size_gb >= 30 && var.os_disk_size_gb <= 2048
    error_message = "OS disk size must be between 30 and 2048 GB."
  }
}

variable "assign_public_ip" {
  description = "Assign public IPs to instances (set false for private-only deployment)"
  type        = bool
  default     = false
}

# Spot Instance Configuration (Cost Optimization)
variable "use_spot_instance" {
  description = "Use Azure Spot VMs for cost savings (60-90% savings)"
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Maximum price for spot instances (-1 for current market price)"
  type        = number
  default     = -1
}

# Storage Configuration
variable "metadata_disk_count" {
  description = "Number of metadata disks per deployment"
  type        = number
  default     = 1
  
  validation {
    condition     = var.metadata_disk_count >= 1 && var.metadata_disk_count <= 4
    error_message = "Metadata disk count must be between 1 and 4."
  }
}

variable "metadata_disk_type" {
  description = "Metadata disk type (auto-selected: LRS for single node, ZRS for multi-zone HA)"
  type        = string
  default     = ""  # Auto-selected based on deployment type
  
  validation {
    condition     = var.metadata_disk_type == "" || contains(["Premium_LRS", "Premium_ZRS", "StandardSSD_LRS", "StandardSSD_ZRS", "UltraSSD_LRS"], var.metadata_disk_type)
    error_message = "Metadata disk type must be empty (auto-select) or one of: Premium_LRS, Premium_ZRS, StandardSSD_LRS, StandardSSD_ZRS, UltraSSD_LRS."
  }
}

variable "metadata_disk_size_gb" {
  description = "Metadata disk size in GB"
  type        = number
  default     = 100
  
  validation {
    condition     = var.metadata_disk_size_gb >= 32 && var.metadata_disk_size_gb <= 32767
    error_message = "Metadata disk size must be between 32 and 32767 GB."
  }
}

# Ultra Disk Configuration (Advanced)
variable "use_ultra_disks" {
  description = "Use Ultra Disks for extreme performance (single-zone only)"
  type        = bool
  default     = false
}

variable "ultra_disk_iops" {
  description = "Ultra Disk IOPS (when use_ultra_disks is true)"
  type        = number
  default     = 40000
  
  validation {
    condition     = var.ultra_disk_iops >= 300 && var.ultra_disk_iops <= 400000
    error_message = "Ultra Disk IOPS must be between 300 and 400000."
  }
}

variable "ultra_disk_throughput_mbps" {
  description = "Ultra Disk throughput in MB/s (when use_ultra_disks is true)"
  type        = number
  default     = 2000
  
  validation {
    condition     = var.ultra_disk_throughput_mbps >= 1 && var.ultra_disk_throughput_mbps <= 10000
    error_message = "Ultra Disk throughput must be between 1 and 10000 MB/s."
  }
}

# Object Storage Configuration
variable "storage_account_type" {
  description = "Storage account type for object storage"
  type        = string
  default     = "Standard_ZRS"  # Cross-zone redundant
  
  validation {
    condition     = contains(["Standard_LRS", "Standard_ZRS", "Standard_GRS", "Premium_LRS", "Premium_ZRS"], var.storage_account_type)
    error_message = "Storage account type must be Standard_LRS, Standard_ZRS, Standard_GRS, Premium_LRS, or Premium_ZRS."
  }
}

variable "storage_size_gb" {
  description = "Logical storage capacity in GB (for planning/display)"
  type        = number
  default     = 1000

  validation {
    condition     = var.storage_size_gb >= 100 && var.storage_size_gb <= 1000000
    error_message = "Storage size must be between 100 and 1000000 GB."
  }
}

variable "bucket_count" {
  description = "Number of Azure Blob containers to create per node for scaling capacity"
  type        = number
  default     = 1

  validation {
    condition     = var.bucket_count >= 1 && var.bucket_count <= 12
    error_message = "Bucket count must be between 1 and 12."
  }
}

# Advanced Features Configuration
variable "enable_accelerated_networking" {
  description = "Enable Accelerated Networking (SR-IOV) for better performance"
  type        = bool
  default     = false
}

variable "disable_secure_boot" {
  description = "Disable Secure Boot for custom MayaNAS kernels (required for custom kernels)"
  type        = bool
  default     = true
}

variable "disable_vtpm" {
  description = "Disable vTPM for custom MayaNAS images (required for custom images)"
  type        = bool
  default     = true
}

variable "enable_proximity_placement_group" {
  description = "Enable Proximity Placement Group for HA deployments (reduces latency)"
  type        = bool
  default     = true
}

variable "performance_tier" {
  description = "Performance tier: standard, high-performance, or ultra"
  type        = string
  default     = "standard"
  
  validation {
    condition     = contains(["standard", "high-performance", "ultra"], var.performance_tier)
    error_message = "Performance tier must be standard, high-performance, or ultra."
  }
}

# Data Persistence
variable "preserve_metadata_disk" {
  description = "Keep metadata disk when VM is terminated"
  type        = bool
  default     = true
}

variable "preserve_storage_account" {
  description = "Keep storage account when deployment is destroyed"
  type        = bool
  default     = true
}

# Resource Tagging
variable "tags" {
  description = "Additional tags for Azure resources"
  type        = map(string)
  default = {
    Project     = "MayaNAS"
    Terraform   = "true"
    Environment = "prod"
  }
}

# MayaNAS Specific Configuration
variable "mayanas_config" {
  description = "MayaNAS-specific configuration options"
  type = object({
    enable_debug_logs    = optional(bool, false)
    custom_startup_script = optional(string, "")
    additional_packages   = optional(list(string), [])
  })
  default = {
    enable_debug_logs    = false
    custom_startup_script = ""
    additional_packages   = []
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


# Azure Provider Configuration (required in v4.x)
variable "subscription_id" {
  description = "Azure subscription ID (required for provider v4.x)"
  type        = string
  default     = ""
}
