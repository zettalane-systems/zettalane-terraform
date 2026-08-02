# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# AWS Lattice pNFS MDS - Variables

variable "region" {
  description = "AWS region for the MDS instance (must match the MayaNAS cluster)"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AZ for the MDS instance. Keep it the same as the MayaNAS nodes: the MDS mounts the DS over NFS, and cross-AZ adds latency and data-transfer charges to every metadata operation. Empty lets AWS pick, which is only safe for a single-subnet VPC."
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC to place the MDS in. Must be the MayaNAS VPC (vpc_id output) so the MDS can reach the DS VIPs. Empty falls back to the account default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet for the MDS. Use the MayaNAS primary_subnet_id output: the DS VIPs are secondary addresses inside that subnet's CIDR, so an MDS elsewhere cannot route to them."
  type        = string
  default     = ""
}

variable "mds_name" {
  description = "Name of the MDS instance"
  type        = string
  default     = "lattice-mds"
}

variable "instance_type" {
  description = "EC2 instance type. m6i.2xlarge (8 vCPU / 32 GB) is ample for a single-node RonDB with small DataMemory plus the Lattice build. Bump RAM if you grow the namespace."
  type        = string
  default     = "m6i.2xlarge"
}

variable "boot_disk_gb" {
  description = "Root volume size (GB). Holds the RonDB DataDir (redo + local checkpoints) and, when building from source, the pnfs-lattice build tree."
  type        = number
  default     = 100
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH. AWS injects this into the AMI's default user; cloud-init additionally installs ssh_public_key for admin_username."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key installed for admin_username via cloud-init"
  type        = string
  sensitive   = true
}

variable "admin_username" {
  description = "Admin username created on the MDS instance"
  type        = string
  default     = "mayanas"
}

variable "use_spot" {
  description = "Use a spot instance for cost savings. Safe for a throwaway MDS; not for a builder, where eviction mid-compile wastes the whole build."
  type        = bool
  default     = true
}

variable "ssh_cidr_blocks" {
  description = "CIDRs allowed to SSH to the MDS"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "source_ami" {
  description = "MDS boot AMI. Empty resolves the newest AMI named lattice-mds-* owned by this account -- the prebuilt image carrying RonDB, pnfs-mds, mds-admin and lattice-genconfig. This image is REQUIRED: the deploy configures an MDS, it does not build one, so there is no stock-image fallback. Unlike GCP images, AMIs are region-scoped, so a freshly published image is only visible in the region it was created in and must be copied to any other."
  type        = string
  default     = ""
}

variable "source_ami_name_filter" {
  description = "Name filter used to find the prebuilt MDS AMI when source_ami is empty"
  type        = string
  default     = "lattice-mds-*"
}
