# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

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

# Marketplace image reference. Defaults to Rocky Linux 9 from RESF (the
# official Rocky Enterprise Software Foundation publisher) because
# Whamcloud's Lustre 2.17 DKMS package builds cleanly against its kernel.
# Rocky 10 is not yet published on Azure Marketplace — the resf SKU "10-base"
# placeholder exists but has no published versions.
# Override per-deployment if you need Ubuntu / RHEL / Alma / etc.
#
# Look up alternatives with:
#   az vm image list --publisher resf --offer rockylinux-x86_64 --all -o table
variable "source_image_publisher" {
  description = "Marketplace publisher (e.g. Canonical, resf, RedHat). Default is Canonical (Ubuntu) — the validate-mayanas / NFS performance test scripts assume a Debian-family client (apt-based). For Lustre clients, deploy-lustre.sh overrides this to resf/rockylinux-x86_64/9-base."
  type        = string
  default     = "Canonical"
}

variable "source_image_offer" {
  description = "Marketplace offer (e.g. ubuntu-24_04-lts, rockylinux-x86_64)"
  type        = string
  default     = "ubuntu-24_04-lts"
}

variable "source_image_sku" {
  description = "Marketplace SKU (e.g. server for Canonical Ubuntu LTS, 9-base for Rocky)."
  type        = string
  default     = "server"
}

variable "source_image_version" {
  description = "Marketplace image version (typically 'latest')"
  type        = string
  default     = "latest"
}
