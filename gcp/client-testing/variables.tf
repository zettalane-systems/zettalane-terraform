# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# GCP Client Testing - Variables

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "zone" {
  description = "GCP zone for client deployment"
  type        = string
  default     = "us-central1-a"
}

variable "client_name" {
  description = "Name of the client instance"
  type        = string
  default     = "mayanas-client"
}

variable "machine_type" {
  description = "GCP machine type"
  type        = string
  default     = "n2-standard-4"
}

variable "ssh_public_key" {
  description = "SSH public key for admin user"
  type        = string
  sensitive   = true
}

variable "admin_username" {
  description = "Admin username for the client VM"
  type        = string
  default     = "mayanas"
}

variable "use_spot" {
  description = "Use spot/preemptible instance for cost savings"
  type        = bool
  default     = true
}

variable "placement_policy_name" {
  description = "Name of placement policy to join for colocation with storage nodes"
  type        = string
  default     = ""
}

variable "source_image" {
  description = "Client boot image (gcloud image spec). Default is Ubuntu 24.04 because the validate-mayanas / NFS performance test scripts assume a Debian-family client (apt-based). For Lustre clients, deploy-lustre.sh overrides this to rocky-linux-cloud/rocky-linux-10 (Whamcloud's Lustre 2.17 DKMS package builds cleanly against its kernel; Ubuntu 24.04 HWE kernel is incompatible with Lustre 2.17 source)."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}
