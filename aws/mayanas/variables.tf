# Image Configuration
variable "ami_id" {
  description = "MayaNAS AMI ID (optional - will auto-detect marketplace AMI if not specified)"
  type        = string
  default     = ""
}

variable "mayanas_product_code" {
  description = "AWS Marketplace product code for MayaNAS (used for auto AMI lookup)"
  type        = string
  default     = "6uq8m459fufly3ohukewdcis1"
}

variable "vpc_id" {
  description = "VPC ID where MayaNAS will be deployed (will auto-select default VPC if not specified)"
  type        = string
  default     = ""
}

variable "availability_zone" {
  description = "AWS availability zone for MayaNAS HA cluster (will auto-select subnet in this AZ). If not specified, intelligently selects cheapest spot price AZ (for spot instances) or random AZ where instance type is available."
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 Key Pair name for SSH access"
  type        = string
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
}

# Compute Configuration
variable "instance_type" {
  description = "EC2 instance type for MayaNAS (any x86-64 instance type)"
  type        = string
  default     = "t3.medium"
}

variable "use_spot_instance" {
  description = "Use spot instances for cost savings (recommended for testing only)"
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Maximum price for spot instances (empty = current spot price)"
  type        = string
  default     = ""
}

# S3 Authentication Method
variable "use_iam_role" {
  description = "Use IAM role authentication (true) or access/secret keys (false, like GCP HMAC)"
  type        = bool
  default     = true
}

variable "boot_disk_type" {
  description = "EBS volume type for boot disk"
  type        = string
  default     = "gp3"
  
  validation {
    condition     = contains(["gp2", "gp3", "io1", "io2"], var.boot_disk_type)
    error_message = "Boot disk type must be one of: gp2, gp3, io1, io2."
  }
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB"
  type        = number
  default     = 20
  
  validation {
    condition     = var.boot_disk_size_gb >= 20 && var.boot_disk_size_gb <= 200
    error_message = "Boot disk size must be between 20 GB and 200 GB."
  }
}

# Storage Configuration
variable "bucket_count" {
  description = "Number of S3 buckets to create per node for scaling capacity"
  type        = number
  default     = 1
  
  validation {
    condition     = var.bucket_count >= 1 && var.bucket_count <= 12
    error_message = "Bucket count must be between 1 and 12."
  }
}

variable "storage_size_gb" {
  description = "Virtual storage capacity in GB (for capacity planning and UI display)"
  type        = number
  default     = 1000

  validation {
    condition     = var.storage_size_gb >= 100 && var.storage_size_gb <= 100000
    error_message = "Storage size must be between 100 GB and 100,000 GB."
  }
}

variable "storage_pool_size" {
  description = "Storage pool size in GB (alias for storage_size_gb for GCP compatibility)"
  type        = number
  default     = null

  validation {
    condition     = var.storage_pool_size == null ? true : (var.storage_pool_size >= 100 && var.storage_pool_size <= 100000)
    error_message = "Storage pool size must be between 100 GB and 100,000 GB, or null to use storage_size_gb."
  }
}

variable "metadata_disk_size_gb" {
  description = "Size of metadata disk in GB (optional - defaults to 10% of storage_size_gb)"
  type        = number
  default     = null
  
  validation {
    condition     = var.metadata_disk_size_gb == null ? true : (var.metadata_disk_size_gb >= 10 && var.metadata_disk_size_gb <= 10000)
    error_message = "Metadata disk size must be between 10 GB and 10,000 GB, or null to auto-calculate."
  }
}

variable "metadata_disk_count" {
  description = "Number of EBS metadata disks per node"
  type        = number
  default     = 1
  
  validation {
    condition     = var.metadata_disk_count >= 1 && var.metadata_disk_count <= 4
    error_message = "Metadata disk count must be between 1 and 4."
  }
}

variable "metadata_disk_type" {
  description = "EBS volume type for metadata disk"
  type        = string
  default     = "gp3"
  
  validation {
    condition     = contains(["gp2", "gp3", "io1", "io2"], var.metadata_disk_type)
    error_message = "Metadata disk type must be one of: gp2, gp3, io1, io2."
  }
}

# S3 Configuration
variable "s3_storage_class" {
  description = "S3 storage class for data buckets (cost optimization)"
  type        = string
  default     = "STANDARD"
  
  validation {
    condition     = contains(["STANDARD", "STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING"], var.s3_storage_class)
    error_message = "S3 storage class must be one of: STANDARD, STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING (archive classes not suitable for active storage)."
  }
}

variable "enable_s3_versioning" {
  description = "Enable S3 bucket versioning for data protection"
  type        = bool
  default     = false
}

variable "preserve_metadata_disk" {
  description = "Preserve metadata disk when instance is terminated"
  type        = bool
  default     = true
}

variable "force_destroy_buckets" {
  description = "Allow terraform to destroy S3 buckets even when they contain objects (prevents accidental data loss when false)"
  type        = bool
  default     = false
}

variable "assign_public_ip" {
  description = "Assign public IPs to instances (set false for private-only deployment)"
  type        = bool
  default     = false
}

# Network Configuration
variable "vip_address" {
  description = "Virtual IP address for HA failover (optional - auto-calculated if not provided)"
  type        = string
  default     = ""
  
  validation {
    condition = var.vip_address == "" || can(regex("^10\\.\\d+\\.\\d+\\.\\d+$", var.vip_address))
    error_message = "VIP address must be empty (auto-calculated) or a valid private IP in 10.x.x.x range."
  }
}

variable "vip_address_2" {
  description = "Second Virtual IP address for active-active deployments (optional - auto-calculated if not provided)"
  type        = string
  default     = ""
  
  validation {
    condition = var.vip_address_2 == "" || can(regex("^10\\.\\d+\\.\\d+\\.\\d+$", var.vip_address_2))
    error_message = "VIP address 2 must be empty (auto-calculated) or a valid private IP in 10.x.x.x range."
  }
}

# Network Security
variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["10.0.0.0/16"]
  
  validation {
    condition = alltrue([
      for cidr in var.ssh_cidr_blocks : can(cidrhost(cidr, 0))
    ])
    error_message = "All SSH CIDR blocks must be valid CIDR notation."
  }
}

# SSH Configuration
variable "ssh_public_key" {
  description = "SSH public key for mayanas service user (optional)"
  type        = string
  default     = ""
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

# Tags
variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
