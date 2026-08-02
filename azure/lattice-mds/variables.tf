# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Azure Lattice pNFS MDS - Variables

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group holding the MayaNAS deployment (MDS joins it)"
  type        = string
}

variable "vnet_name" {
  description = "Virtual network of the MayaNAS storage nodes — the MDS must share it to reach the DS VIPs"
  type        = string
}

variable "subnet_name" {
  description = "Subnet within that VNet"
  type        = string
}

variable "mds_name" {
  description = "Name of the MDS VM"
  type        = string
  default     = "lattice-mds"
}

variable "vm_size" {
  description = "Azure VM size. Standard_D8as_v6 (32GB RAM) is ample for a single-node RonDB with small DataMemory plus the Lattice build. Bump RAM if you grow the namespace."
  type        = string
  default     = "Standard_D8as_v6"
}

variable "boot_disk_gb" {
  description = "OS disk size (GB). Holds the RonDB DataDir (redo + local checkpoints) and the pnfs-lattice build tree."
  type        = number
  default     = 100
}

variable "ssh_public_key" {
  description = "SSH public key for admin user"
  type        = string
  sensitive   = true
}

variable "admin_username" {
  description = "Admin username for the MDS VM"
  type        = string
  default     = "mayanas"
}

variable "ssh_cidr_blocks" {
  description = "CIDRs allowed to SSH to the MDS"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "use_spot" {
  description = "Use a Spot VM for cost savings (evicts to Deallocate, so the disk survives)"
  type        = bool
  default     = true
}

variable "proximity_placement_group_id" {
  description = "Optional PPG for colocation with the storage nodes + client"
  type        = string
  default     = ""
}

variable "mds_image_id" {
  description = "Explicit MDS image id, community-gallery or resource id. Leave empty to auto-select the prebuilt lattice-mds community image for this region. There is no fallback image: the deploy configures an MDS rather than building one, so a region without the image is an error."
  type        = string
  default     = ""
}

variable "mds_community_gallery" {
  description = "Public name of the ZettaLane community gallery probed for the prebuilt MDS image."
  type        = string
  default     = "zettalane-81d42575-10ae-47f7-9859-d497d576683e"
}

variable "mds_image_definition" {
  description = "Community image definition holding the prebuilt Lattice MDS: pnfs-mds, mds-admin, RonDB and the source tree, with RonDB uninitialised."
  type        = string
  default     = "lattice-mds"
}

# --- Fallback image, used only when no prebuilt MDS image is found -------------



