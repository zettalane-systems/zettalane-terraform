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
  description = "Client boot image (gcloud image spec). Rocky 10 is the default because Whamcloud's Lustre 2.17 DKMS package builds cleanly against its kernel. Ubuntu 22.04 also works (--client-image ubuntu-os-cloud/ubuntu-2204-lts); Ubuntu 24.04 HWE kernel is currently incompatible with Lustre 2.17 source."
  type        = string
  default     = "rocky-linux-cloud/rocky-linux-10"
}
