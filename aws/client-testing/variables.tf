# AWS Client Testing - Variables

variable "key_pair_name" {
  description = "AWS EC2 Key Pair name"
  type        = string
}

variable "client_name" {
  description = "Name of the client instance"
  type        = string
  default     = "mayanas-client"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "c6in.xlarge"
}

variable "ssh_public_key" {
  description = "SSH public key for admin user"
  type        = string
  default     = ""
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
