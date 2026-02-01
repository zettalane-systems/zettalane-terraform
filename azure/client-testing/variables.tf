# Azure Client Testing - Variables

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Azure resource group name"
  type        = string
}

variable "vnet_name" {
  description = "Virtual network name"
  type        = string
}

variable "subnet_name" {
  description = "Subnet name"
  type        = string
}

variable "location" {
  description = "Azure location"
  type        = string
  default     = ""
}

variable "client_name" {
  description = "Name of the client instance"
  type        = string
  default     = "mayanas-client"
}

variable "vm_size" {
  description = "Azure VM size"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "ssh_public_key" {
  description = "SSH public key for admin user"
  type        = string
}

variable "admin_username" {
  description = "Admin username for the client VM"
  type        = string
  default     = "mayanas"
}

variable "use_spot" {
  description = "Use spot instance for cost savings"
  type        = bool
  default     = true
}

variable "proximity_placement_group_id" {
  description = "Proximity placement group ID for colocation with storage nodes"
  type        = string
  default     = ""
}
