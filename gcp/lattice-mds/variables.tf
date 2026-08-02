# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# GCP Lattice pNFS MDS - Variables

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "zone" {
  description = "GCP zone for the MDS VM (keep same zone as MayaNAS nodes + client)"
  type        = string
  default     = "us-central1-a"
}

variable "mds_name" {
  description = "Name of the MDS instance"
  type        = string
  default     = "lattice-mds"
}

variable "machine_type" {
  description = "GCP machine type. n2-standard-8 (32GB RAM) is ample for a single-node RonDB with small DataMemory + the Lattice build. Bump RAM if you grow the namespace."
  type        = string
  default     = "n2-standard-8"
}

variable "boot_disk_gb" {
  description = "Boot disk size (GB). Holds the RonDB DataDir (redo + local checkpoints) and the pnfs-lattice build tree."
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

variable "use_spot" {
  description = "Use spot/preemptible instance for cost savings"
  type        = bool
  default     = true
}

variable "placement_policy_name" {
  description = "Optional placement policy for colocation with storage nodes"
  type        = string
  default     = ""
}

variable "source_image" {
  description = "MDS boot image. Defaults to the prebuilt lattice-mds community image, which carries RonDB, pnfs-mds, mds-admin and lattice-genconfig. This image is required: the deploy configures an MDS, it does not build one, so a stock image is not a usable substitute. Unlike AMIs and Azure gallery versions, GCP images are global, so one publish covers every region."
  type        = string
  default     = "zettalane-public/lattice-mds"
}
