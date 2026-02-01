# Azure MayaScale Terraform Variables
# NVMeoF storage cluster with local ephemeral NVMe

# ============================================================================
# REQUIRED VARIABLES
# ============================================================================

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the MayaScale cluster (max 15 chars for resource naming)"
  type        = string

  validation {
    condition     = length(var.cluster_name) <= 15 && can(regex("^[a-z0-9-]+$", var.cluster_name))
    error_message = "Cluster name must be 15 chars or less and contain only lowercase letters, numbers, and hyphens"
  }
}

variable "location" {
  description = "Azure region (e.g., westus, eastus, westeurope)"
  type        = string
  default     = "westus"
}

variable "ssh_public_key" {
  description = "SSH public key for VM access (provide key content OR use ssh_key_vault_id)"
  type        = string
  default     = ""
}

# ============================================================================
# PERFORMANCE TIER CONFIGURATION
# ============================================================================

variable "performance_policy" {
  description = "Performance and availability policy for storage cluster"
  type        = string
  default     = "regional-standard-performance"

  validation {
    condition = contains([
      # Regional (cross-zone HA) - Write IOPS ~0.83× due to cross-zone replication, ~1.5ms latency
      "regional-basic-performance",          # 137.5K read / 46K write, L2as_v4, 1 NVMe, 12.5 Gbps, cross-zone HA
      "regional-standard-performance",       # 360K read / 120K write, L4aos_v4, 3 NVMe, 10 Gbps, cross-zone HA
      "regional-medium-performance",         # 720K read / 240K write, L8aos_v4, 6 NVMe, 12.5 Gbps, cross-zone HA
      "regional-high-performance",           # 2.16M read / 720K write, L24aos_v4, 9 NVMe, 37.5 Gbps, cross-zone HA
      "regional-ultra-performance",          # 2.88M read / 960K write, L32aos_v4, 12 NVMe, 50 Gbps, cross-zone HA
      # Zonal (same-zone) - Higher write IOPS (no cross-zone penalty), ~1ms latency
      "zonal-basic-performance",             # 137.5K read / 55K write, L2as_v4, 1 NVMe, 12.5 Gbps, same-zone
      "zonal-standard-performance",          # 360K read / 144K write, L4aos_v4, 3 NVMe, 10 Gbps, same-zone
      "zonal-medium-performance",            # 720K read / 288K write, L8aos_v4, 6 NVMe, 12.5 Gbps, same-zone
      "zonal-high-performance",              # 2.16M read / 864K write, L24aos_v4, 9 NVMe, 37.5 Gbps, same-zone
      "zonal-ultra-performance"              # 2.88M read / 1.15M write, L32aos_v4, 12 NVMe, 50 Gbps, same-zone
    ], var.performance_policy)
    error_message = "Performance policy must be one of the predefined options: [regional|zonal]-[basic|standard|medium|high|ultra]-performance"
  }
}

# Note: All tiers map to optimal instances based on NVMe device count
# Laosv4 is preferred (better bandwidth, more NVMe, lower cost)
# basic: 1 NVMe (lasv4 only), standard: 2-3 NVMe, medium: 4-6 NVMe, high: 8-10 NVMe, ultra: 12 NVMe

variable "instance_family" {
  description = "Azure L-series family: laosv4 (AMD optimized, BEST VALUE, default), lasv4 (AMD full range), lsv3 (Intel Ice Lake), lsv2 (Intel Cascade Lake)"
  type        = string
  default     = "laosv4"

  validation {
    condition     = contains(["lasv4", "laosv4", "lsv3", "lsv2"], var.instance_family)
    error_message = "Instance family must be: lasv4, laosv4, lsv3, or lsv2"
  }
}

# Performance tier mapping (Azure L-series with local ephemeral NVMe)
# Supports 4 instance families: Lasv4 (AMD), Laosv4 (AMD optimized), Lsv3 (Intel Ice Lake), Lsv2 (Intel Cascade Lake)
locals {
  # Extract tier from policy name (e.g., "regional-ultra-performance" → "ultra", "zonal-basic-performance" → "basic")
  # Policy format: [zonal|regional]-[basic|standard|medium|high|ultra]-performance
  policy_parts = split("-", var.performance_policy)
  tier         = local.policy_parts[1] # Second part is the tier (basic/standard/medium/high/ultra)

  # Extract availability strategy
  availability_strategy = local.policy_parts[0] # "zonal" or "regional"

  # Instance name mapping: tier → family → vm_size
  # Laosv4 is preferred: better bandwidth, more NVMe devices, lower cost
  instance_map = {
    basic = {
      lasv4  = "Standard_L2as_v4"   # 2 vCPU, 16GB RAM, 1 NVMe, 12.5 Gbps (active-passive only)
      laosv4 = "Standard_L4aos_v4"  # 4 vCPU, 32GB RAM, 3 NVMe, 10 Gbps (fallback to standard)
      lsv3   = "Standard_L8s_v3"    # 8 vCPU, 64GB RAM, 1 NVMe, 12.5 Gbps
      lsv2   = "Standard_L8s_v2"    # 8 vCPU, 64GB RAM, 1 NVMe, 3.2 Gbps
    }
    standard = {
      lasv4  = "Standard_L4as_v4"   # 4 vCPU, 32GB RAM, 2 NVMe, 12.5 Gbps
      laosv4 = "Standard_L4aos_v4"  # 4 vCPU, 32GB RAM, 3 NVMe, 10 Gbps (BEST VALUE)
      lsv3   = "Standard_L16s_v3"   # 16 vCPU, 128GB RAM, 2 NVMe, 12.5 Gbps
      lsv2   = "Standard_L16s_v2"   # 16 vCPU, 128GB RAM, 2 NVMe, 6.4 Gbps
    }
    medium = {
      lasv4  = "Standard_L8as_v4"   # 8 vCPU, 64GB RAM, 4 NVMe, 12.5 Gbps
      laosv4 = "Standard_L8aos_v4"  # 8 vCPU, 64GB RAM, 6 NVMe, 12.5 Gbps (BEST VALUE)
      lsv3   = "Standard_L32s_v3"   # 32 vCPU, 256GB RAM, 4 NVMe, 16 Gbps
      lsv2   = "Standard_L32s_v2"   # 32 vCPU, 256GB RAM, 4 NVMe, 12.8 Gbps
    }
    high = {
      lasv4  = "Standard_L64as_v4"  # 64 vCPU, 512GB RAM, 8 NVMe, 36 Gbps
      laosv4 = "Standard_L24aos_v4" # 24 vCPU, 192GB RAM, 9 NVMe, 37.5 Gbps (BEST VALUE)
      lsv3   = "Standard_L64s_v3"   # 64 vCPU, 512GB RAM, 8 NVMe, 30 Gbps
      lsv2   = "Standard_L64s_v2"   # 64 vCPU, 512GB RAM, 8 NVMe, 16 Gbps
    }
    ultra = {
      lasv4  = "Standard_L96as_v4"  # 96 vCPU, 768GB RAM, 12 NVMe, 40 Gbps
      laosv4 = "Standard_L32aos_v4" # 32 vCPU, 256GB RAM, 12 NVMe, 50 Gbps (BEST VALUE)
      lsv3   = "Standard_L80s_v3"   # 80 vCPU, 640GB RAM, 10 NVMe, 32 Gbps
      lsv2   = "Standard_L80s_v2"   # 80 vCPU, 640GB RAM, 10 NVMe, 16 Gbps
    }
  }

  # Performance tier specifications (based on Laosv4 - best bandwidth & value)
  # Read IOPS from Azure specs, Write IOPS = Read × 0.4 (ZFS NVMeoF overhead)
  performance_tiers = {
    # Basic: Development/test - L2as_v4 (active-passive, 1 NVMe)
    basic = {
      network_gbps     = 12.5
      nvme_capacity_tb = 0.48
      nvme_devices     = 1
      target_read_iops  = 137500
      target_write_iops = 55000
      target_bw_mbps = 12500
      cost_per_month   = 25
      deployment_mode  = "active-passive"
    }

    # Standard: Entry active-active - L4aos_v4 (3 NVMe)
    standard = {
      network_gbps     = 10
      nvme_capacity_tb = 2.88
      nvme_devices     = 3
      target_read_iops  = 360000
      target_write_iops = 144000
      target_bw_mbps = 10000
      cost_per_month   = 45
      deployment_mode  = "active-active"
    }

    # Medium: Production workloads - L8aos_v4 (6 NVMe)
    medium = {
      network_gbps     = 12.5
      nvme_capacity_tb = 5.76
      nvme_devices     = 6
      target_read_iops  = 720000
      target_write_iops = 288000
      target_bw_mbps = 12500
      cost_per_month   = 100
      deployment_mode  = "active-active"
    }

    # High: High-performance workloads - L24aos_v4 (9 NVMe)
    high = {
      network_gbps     = 37.5
      nvme_capacity_tb = 17.28
      nvme_devices     = 9
      target_read_iops  = 2160000
      target_write_iops = 864000
      target_bw_mbps = 37500
      cost_per_month   = 300
      deployment_mode  = "active-active"
    }

    # Ultra: Maximum performance - L32aos_v4 (12 NVMe)
    ultra = {
      network_gbps     = 50
      nvme_capacity_tb = 23.04
      nvme_devices     = 12
      target_read_iops  = 2880000
      target_write_iops = 1152000
      target_bw_mbps = 50000
      cost_per_month   = 400
      deployment_mode  = "active-active"
    }
  }

  # Validate instance family supports requested performance tier
  selected_instance = local.instance_map[local.tier][var.instance_family]

  # Selected tier configuration
  selected_tier = local.performance_tiers[local.tier]
  vm_size       = var.vm_size_override != "" ? var.vm_size_override : local.selected_instance
}

variable "vm_size_override" {
  description = "Override performance tier with specific VM size (e.g., Standard_L8as_v5)"
  type        = string
  default     = ""
}

# ============================================================================
# CLUSTER CONFIGURATION
# ============================================================================

variable "node_count" {
  description = "Number of storage nodes in cluster (2-16)"
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 2 && var.node_count <= 16
    error_message = "Node count must be between 2 and 16 for MayaScale cluster"
  }
}

variable "replica_count" {
  description = "Number of data replicas (1=no replication, 2=mirrored, 3=triple)"
  type        = number
  default     = 2

  validation {
    condition     = contains([1, 2, 3], var.replica_count)
    error_message = "Replica count must be 1, 2, or 3"
  }
}

# ============================================================================
# NETWORKING
# ============================================================================

variable "resource_group_name" {
  description = "Existing resource group name (leave empty to create new)"
  type        = string
  default     = ""
}

variable "vnet_name" {
  description = "Existing VNet name (leave empty to create new)"
  type        = string
  default     = ""
}

variable "subnet_name" {
  description = "Existing subnet name (leave empty to create new)"
  type        = string
  default     = ""
}

variable "vnet_cidr" {
  description = "CIDR block for VNet (if creating new)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for primary subnet - client traffic (if creating new)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "backend_subnet_cidr" {
  description = "CIDR block for backend subnet - storage replication traffic (regional, spans all zones)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "enable_accelerated_networking" {
  description = "Enable accelerated networking (SR-IOV) for better performance"
  type        = bool
  default     = true
}

variable "vip_address" {
  description = "Virtual IP address for cluster (auto-generated from subnet if empty)"
  type        = string
  default     = ""
}

variable "vip_address_2" {
  description = "Second Virtual IP address for multi-node cluster (auto-generated if empty)"
  type        = string
  default     = ""
}

variable "vip_mechanism" {
  description = "VIP mechanism: custom-route (Azure route tables) or load-balancer (Azure Load Balancer)"
  type        = string
  default     = "custom-route"

  validation {
    condition     = contains(["custom-route", "load-balancer"], var.vip_mechanism)
    error_message = "VIP mechanism must be either 'custom-route' or 'load-balancer'"
  }
}

# ============================================================================
# PLACEMENT AND AVAILABILITY
# ============================================================================

variable "availability_zones" {
  description = "List of availability zones to use (e.g., [1, 2, 3])"
  type        = list(number)
  default     = [1, 2]
}

variable "zone_strategy" {
  description = "Availability zone strategy: same-zone (all nodes in zone 1) or cross-zone (nodes spread across zones)"
  type        = string
  default     = "cross-zone"

  validation {
    condition     = contains(["same-zone", "cross-zone"], var.zone_strategy)
    error_message = "Zone strategy must be: same-zone or cross-zone"
  }
}

variable "enable_proximity_placement_group" {
  description = "Enable proximity placement group for ultra-low latency between nodes (automatically disabled for regional cross-zone policies)"
  type        = bool
  default     = true
}

# ============================================================================
# SPOT INSTANCES
# ============================================================================

variable "use_spot_instances" {
  description = "Use spot instances for cost savings (60-80% cheaper)"
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Maximum price for spot instances (-1 = accept current market price)"
  type        = number
  default     = -1
}

# ============================================================================
# OS AND IMAGES
# ============================================================================

variable "vm_image_id" {
  description = "Custom VM image ID (leave empty for marketplace Ubuntu 20.04)"
  type        = string
  default     = ""
}

variable "os_disk_type" {
  description = "OS disk type (Premium_LRS, StandardSSD_LRS)"
  type        = string
  default     = "Premium_LRS"
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 128
}

variable "admin_username" {
  description = "Admin username for VMs"
  type        = string
  default     = "azureuser"
}

# ============================================================================
# SSH KEY ALTERNATIVES
# ============================================================================

variable "ssh_key_vault_id" {
  description = "Azure Key Vault secret ID containing SSH public key"
  type        = string
  default     = ""
}

variable "ssh_key_resource_id" {
  description = "Azure SSH Public Key resource ID"
  type        = string
  default     = ""
}

# ============================================================================
# SECURITY
# ============================================================================

variable "disable_secure_boot" {
  description = "Disable secure boot (needed for custom kernels)"
  type        = bool
  default     = true
}

variable "disable_vtpm" {
  description = "Disable vTPM (needed for some custom kernels)"
  type        = bool
  default     = true
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed for SSH access (empty = allow all)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_nvmeof_cidrs" {
  description = "CIDR blocks allowed for NVMeoF access (empty = allow from subnet only)"
  type        = list(string)
  default     = []
}

# ============================================================================
# TAGS
# ============================================================================

variable "tags" {
  description = "Additional tags for all resources"
  type        = map(string)
  default     = {}
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "selected_performance_tier" {
  description = "Details of the selected performance tier"
  value = {
    tier                = var.performance_policy
    vm_size             = local.vm_size
    network_gbps        = local.selected_tier.network_gbps
    nvme_capacity_tb    = local.selected_tier.nvme_capacity_tb
    nvme_devices        = local.selected_tier.nvme_devices
    expected_read_iops  = local.selected_tier.target_read_iops
    expected_write_iops = local.selected_tier.target_write_iops
    expected_bw_mbps    = local.selected_tier.target_bw_mbps
    deployment_mode     = local.selected_tier.deployment_mode
    cost_per_node       = local.selected_tier.cost_per_month
    total_cost          = local.selected_tier.cost_per_month * var.node_count
  }
}

# ============================================================================
# CLIENT ACCESS CONFIGURATION
# ============================================================================

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