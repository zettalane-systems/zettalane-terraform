terraform {
  required_version = ">= 0.14"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    template = {
      source  = "hashicorp/template"
      version = ">= 2.2"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# AWS Provider configuration with reduced retries for faster failure on spot unavailability
provider "aws" {
  # Reduce retry attempts for spot instance requests from default 25 to 3
  # This fails faster when spot capacity is unavailable (minutes instead of ~50 minutes)
  max_retries = 10

  # Use standard retry mode (default, but explicit for clarity)
  retry_mode = "standard"
}

# Generate unique suffix for resources
resource "random_id" "suffix" {
  byte_length = 4
}

# Generate random password for MayaNAS instances
resource "random_password" "mayanas_password" {
  length  = 16
  special = true
  upper   = true
  lower   = true
  numeric = true
}

# Generate cluster resource IDs for unique naming
resource "random_integer" "resource_id" {
  min = 1
  max = 255
}

# Second resource ID for active-active deployments
resource "random_integer" "peer_resource_id" {
  min = 1
  max = 255
}

# Data sources for AWS resources
data "aws_region" "current" {}

# Auto-detect MayaNAS marketplace AMI by product code
data "aws_ami" "mayanas_marketplace" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "product-code"
    values = [var.mayanas_product_code]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  # Use specified AMI or auto-detected marketplace AMI
  resolved_ami_id = var.ami_id != "" ? var.ami_id : (
    length(data.aws_ami.mayanas_marketplace) > 0 ? data.aws_ami.mayanas_marketplace[0].id : ""
  )
}

data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

locals {
  selected_vpc_id = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
  device_names = ["/dev/sdf", "/dev/sdg", "/dev/sdh", "/dev/sdi", "/dev/sdj", "/dev/sdk"]
}

data "aws_vpc" "selected" {
  id = local.selected_vpc_id
}

data "aws_subnets" "available" {
  filter {
    name   = "vpc-id"
    values = [local.selected_vpc_id]
  }
  
  filter {
    name   = "availability-zone"
    values = [var.availability_zone != "" ? var.availability_zone : (
      var.use_spot_instance ? local.cheapest_az : random_shuffle.available_azs.result[0]
    )]
  }
}

data "aws_subnet" "selected" {
  id = data.aws_subnets.available.ids[0]
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Check instance type availability across AZs for intelligent selection
data "aws_ec2_instance_type_offerings" "available" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
  location_type = "availability-zone"
}

# Get spot prices for all available AZs to select cheapest
data "aws_ec2_spot_price" "available_azs" {
  for_each = toset(data.aws_ec2_instance_type_offerings.available.locations)
  
  instance_type     = var.instance_type
  availability_zone = each.key
  
  filter {
    name   = "product-description"
    values = ["Linux/UNIX"]
  }
}

# Fallback random selection if spot price logic fails
resource "random_shuffle" "available_azs" {
  input = data.aws_ec2_instance_type_offerings.available.locations
  result_count = 1
}

# Local variables for configuration
locals {
  # Spot price analysis for intelligent AZ selection
  spot_prices = {
    for az, price_data in data.aws_ec2_spot_price.available_azs :
    az => try(tonumber(price_data.spot_price), 999.99) # Use high fallback price if unavailable
  }
  
  # Find AZ with minimum spot price
  cheapest_az = length(local.spot_prices) > 0 ? [
    for az, price in local.spot_prices :
    az if price == min(values(local.spot_prices)...)
  ][0] : data.aws_ec2_instance_type_offerings.available.locations[0]
  
  # Cluster naming
  effective_cluster_name = var.cluster_name != "" ? var.cluster_name : "mayanas-${random_id.suffix.hex}"
  
  # Deployment configuration
  is_ha_deployment = contains(["active-passive", "active-active"], var.deployment_type)
  node_count = var.deployment_type == "active-active" ? 2 : (local.is_ha_deployment ? 2 : 1)
  
  # Availability zone (user-specified or intelligently selected based on spot pricing)
  selected_az = var.availability_zone != "" ? var.availability_zone : (
    var.use_spot_instance ? local.cheapest_az : random_shuffle.available_azs.result[0]
  )
  
  # Internal subnet/zone variables (auto-discovered from AZ)
  primary_subnet_id   = data.aws_subnet.selected.id
  secondary_subnet_id = data.aws_subnet.selected.id  # Same subnet for same-zone HA
  primary_az          = local.selected_az
  secondary_az        = local.selected_az  # Same AZ for same-zone HA
  
  # VIP configuration for AWS (same-zone HA)
  # AWS uses secondary private IPs instead of alias IPs
  # Dynamic collision detection handled in startup script
  vip_address = var.vip_address != "" ? var.vip_address : cidrhost(data.aws_subnet.selected.cidr_block, 100)
  # Active-active uses separate VIPs in same subnet
  vip_address_2 = var.deployment_type == "active-active" ? (
    var.vip_address_2 != "" ? var.vip_address_2 : cidrhost(data.aws_subnet.selected.cidr_block, 101)
  ) : ""
  
  # Per-node resource allocation
  total_bucket_count = var.deployment_type == "active-active" ? var.bucket_count * 2 : var.bucket_count
  total_metadata_disk_count = var.deployment_type == "active-active" ? var.metadata_disk_count * 2 : var.metadata_disk_count
  
  # Storage configuration  
  metadata_disk_size_gb = var.metadata_disk_size_gb != null ? var.metadata_disk_size_gb : max(100, ceil(var.storage_size_gb * 0.1))
  
  # All bucket names for startup script configuration
  bucket_names = [for bucket in aws_s3_bucket.mayanas_data : bucket.id]
  
  # All EBS volume names for startup script configuration
  metadata_disk_names = [for disk in aws_ebs_volume.mayanas_metadata : disk.id]
}

# IAM role for MayaNAS instances (HA deployments only)
resource "aws_iam_role" "mayanas_role" {
  count = var.use_iam_role ? 1 : 0
  
  name = "${local.effective_cluster_name}-mayanas-role-${random_id.suffix.hex}"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(var.tags, {
    Name         = "${local.effective_cluster_name}-mayanas-role"
    ClusterName  = local.effective_cluster_name
    DeploymentType = var.deployment_type
  })
}

# IAM policy for HA operations
resource "aws_iam_policy" "mayanas_ha_policy" {
  count = local.is_ha_deployment ? 1 : 0
  
  name = "${local.effective_cluster_name}-mayanas-ha-policy-${random_id.suffix.hex}"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # EC2 permissions for HA operations (VIP, network, and instance management)
      {
        Effect = "Allow"
        Action = [
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeRouteTables",
          "ec2:AttachNetworkInterface",
          "ec2:DetachNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:AssociateAddress",
          "ec2:RebootInstances",
          "ec2:StopInstances",
          "ec2:StartInstances"
        ]
        Resource = "*"
      },
      # EBS permissions for metadata disk failover operations
      {
        Effect = "Allow"
        Action = [
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumeStatus"
        ]
        Resource = "*"
      },
      # S3 permissions for comprehensive data access and bucket operations
      {
        Effect = "Allow"
        Action = [
          "s3:Get*",
          "s3:Put*",
          "s3:Delete*",
          "s3:List*",
          "s3:CreateBucket"
        ]
        Resource = [
          for bucket in aws_s3_bucket.mayanas_data : "${bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:Get*",
          "s3:Put*",
          "s3:Delete*",
          "s3:List*",
          "s3:CreateBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          for bucket in aws_s3_bucket.mayanas_data : bucket.arn
        ]
      },
      # S3 service-level permissions for global operations
      {
        Effect = "Allow"
        Action = [
          "s3:ListAllMyBuckets",
          "s3:GetBucketLocation",
          "s3:CreateBucket"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, {
    Name         = "${local.effective_cluster_name}-mayanas-ha-policy"
    ClusterName  = local.effective_cluster_name
    DeploymentType = var.deployment_type
  })
}

# IAM policy for single deployment (S3-only permissions)
resource "aws_iam_policy" "mayanas_single_policy" {
  count = local.is_ha_deployment ? 0 : 1
  
  name = "${local.effective_cluster_name}-mayanas-single-policy-${random_id.suffix.hex}"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3 permissions for data access
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          for bucket in aws_s3_bucket.mayanas_data : "${bucket.arn}/*"
        ]
      },
      # S3 bucket-level permissions
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject", 
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          for bucket in aws_s3_bucket.mayanas_data : bucket.arn
        ]
      },
      # S3 global permissions
      {
        Effect = "Allow"
        Action = [
          "s3:ListAllMyBuckets",
          "s3:GetBucketLocation"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, {
    Name            = "${local.effective_cluster_name}-mayanas-single-policy"
    ClusterName     = local.effective_cluster_name
    DeploymentType  = var.deployment_type
  })
}

# Attach HA policy to role (HA deployments)
resource "aws_iam_role_policy_attachment" "mayanas_ha_attachment" {
  count = local.is_ha_deployment ? 1 : 0
  
  role       = aws_iam_role.mayanas_role[0].name
  policy_arn = aws_iam_policy.mayanas_ha_policy[0].arn
}

# Attach single policy to role (single deployments)  
resource "aws_iam_role_policy_attachment" "mayanas_single_attachment" {
  count = local.is_ha_deployment ? 0 : 1
  
  role       = aws_iam_role.mayanas_role[0].name
  policy_arn = aws_iam_policy.mayanas_single_policy[0].arn
}

# Instance profile for EC2 instances
resource "aws_iam_instance_profile" "mayanas_profile" {
  count = var.use_iam_role ? 1 : 0
  
  name = "${local.effective_cluster_name}-mayanas-profile-${random_id.suffix.hex}"
  role = aws_iam_role.mayanas_role[0].name

  tags = merge(var.tags, {
    Name         = "${local.effective_cluster_name}-mayanas-profile"
    ClusterName  = local.effective_cluster_name
    DeploymentType = var.deployment_type
  })
}

# IAM User for S3 access (alternative to role-based auth, matches GCP HMAC pattern)
resource "aws_iam_user" "mayanas_s3_user" {
  count = var.use_iam_role ? 0 : 1
  name  = "${local.effective_cluster_name}-s3-user-${random_id.suffix.hex}"
  
  tags = merge(var.tags, {
    Name           = "${local.effective_cluster_name}-s3-user"
    ClusterName    = local.effective_cluster_name
    DeploymentType = var.deployment_type
  })
}

# S3 access policy for IAM user
resource "aws_iam_user_policy" "mayanas_s3_policy" {
  count = var.use_iam_role ? 0 : 1
  name  = "S3AccessPolicy"
  user  = aws_iam_user.mayanas_s3_user[0].name
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject", 
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = concat(
          [for bucket in aws_s3_bucket.mayanas_data : bucket.arn],
          [for bucket in aws_s3_bucket.mayanas_data : "${bucket.arn}/*"]
        )
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListAllMyBuckets",
          "s3:GetBucketLocation"
        ]
        Resource = "*"
      }
    ]
  })
}

# Generate access keys for IAM user
resource "aws_iam_access_key" "mayanas_s3_key" {
  count = var.use_iam_role ? 0 : 1
  user  = aws_iam_user.mayanas_s3_user[0].name
}

# S3 buckets for shared data storage
resource "aws_s3_bucket" "mayanas_data" {
  count = local.total_bucket_count
  
  bucket        = "${local.effective_cluster_name}-data-${count.index}-${random_id.suffix.hex}"
  force_destroy = var.force_destroy_buckets

  tags = merge(var.tags, {
    Name            = "${local.effective_cluster_name}-data-${count.index}"
    Type            = "mayanas-object-storage"
    ClusterName     = local.effective_cluster_name
    DeploymentType  = var.deployment_type
    BucketIndex     = tostring(count.index)
    # Node assignment for active-active: 0-(count-1) = node1, count-(2*count-1) = node2
    NodeAssignment  = var.deployment_type == "active-active" ? (count.index < var.bucket_count ? "node1" : "node2") : "shared"
  })
}

# S3 bucket server-side encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "mayanas_data_encryption" {
  count = local.total_bucket_count
  
  bucket = aws_s3_bucket.mayanas_data[count.index].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3 bucket versioning (optional)
resource "aws_s3_bucket_versioning" "mayanas_data_versioning" {
  count = var.enable_s3_versioning ? local.total_bucket_count : 0
  
  bucket = aws_s3_bucket.mayanas_data[count.index].id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 bucket public access block
resource "aws_s3_bucket_public_access_block" "mayanas_data_pab" {
  count = local.total_bucket_count
  
  bucket = aws_s3_bucket.mayanas_data[count.index].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 storage class configuration (applied during object creation via lifecycle rules)
resource "aws_s3_bucket_lifecycle_configuration" "mayanas_data_lifecycle" {
  count = var.s3_storage_class != "STANDARD" ? local.total_bucket_count : 0
  
  bucket = aws_s3_bucket.mayanas_data[count.index].id

  rule {
    id     = "storage_class_transition"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 0
      storage_class = var.s3_storage_class
    }
  }
}

# EBS volumes for metadata storage (distributed based on deployment type)
resource "aws_ebs_volume" "mayanas_metadata" {
  count = local.total_metadata_disk_count
  
  # For same-zone HA: all volumes in same AZ
  # Future: could use different AZs if AWS supports cross-zone EBS
  availability_zone = count.index < var.metadata_disk_count ? local.primary_az : local.secondary_az
  size             = local.metadata_disk_size_gb
  type             = var.metadata_disk_type
  encrypted        = true

  tags = merge(var.tags, {
    Name           = "${local.effective_cluster_name}-metadata-${count.index}"
    Type           = "mayanas-metadata"
    ClusterName    = local.effective_cluster_name
    DeploymentType = var.deployment_type
    DiskIndex      = tostring(count.index)
    # Node assignment for active-active: 0-(count-1) = node1, count-(2*count-1) = node2
    NodeAssignment = var.deployment_type == "active-active" ? (count.index < var.metadata_disk_count ? "node1" : "node2") : "shared"
  })
}

# Security group for MayaNAS cluster
resource "aws_security_group" "mayanas_sg" {
  name_prefix = "${local.effective_cluster_name}-mayanas-"
  vpc_id      = local.selected_vpc_id

  # SSH access from specified CIDR blocks
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  # Allow all traffic from VPC CIDR (for clients, monitoring, etc.)
  ingress {
    description = "All traffic from VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  # All outbound traffic
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name         = "${local.effective_cluster_name}-mayanas-sg"
    ClusterName  = local.effective_cluster_name
    DeploymentType = var.deployment_type
  })
}

# Startup script template
locals {
  startup_script_primary = templatefile("${path.module}/startup.sh.tpl", {
    cluster_name            = local.effective_cluster_name
    deployment_type         = var.deployment_type
    node_role              = var.deployment_type == "active-active" ? "node1" : "primary"
    vip_address            = local.vip_address
    vip_address_2          = local.vip_address_2
    bucket_names           = join(" ", local.bucket_names)
    peer_zone              = local.secondary_az
    metadata_disk_names    = join(" ", local.metadata_disk_names)
    metadata_disk_node1    = aws_ebs_volume.mayanas_metadata[0].id
    metadata_disk_node2    = local.is_ha_deployment && var.deployment_type == "active-active" ? aws_ebs_volume.mayanas_metadata[1].id : ""
    # For active-active: split buckets between nodes (first half = node1, second half = node2)
    # For other deployments: all buckets for node1, empty for node2
    bucket_node1          = var.deployment_type == "active-active" ? join(" ", slice(local.bucket_names, 0, var.bucket_count)) : join(" ", local.bucket_names)
    bucket_node2          = var.deployment_type == "active-active" ? join(" ", slice(local.bucket_names, var.bucket_count, local.total_bucket_count)) : ""
    ssh_public_key         = var.ssh_public_key
    node_count             = local.node_count
    bucket_count           = var.bucket_count
    metadata_disk_count    = var.metadata_disk_count
    metadata_disk_size_gb  = local.metadata_disk_size_gb
    storage_size_gb        = var.storage_size_gb
    resource_id            = random_integer.resource_id.result
    peer_resource_id       = random_integer.peer_resource_id.result
    availability_zone      = local.primary_az
    # S3 credentials (conditional based on authentication method)
    s3_access_key          = var.use_iam_role ? aws_iam_role.mayanas_role[0].name : aws_iam_access_key.mayanas_s3_key[0].id
    s3_secret_key          = var.use_iam_role ? "" : aws_iam_access_key.mayanas_s3_key[0].secret
    # AWS-specific variables
    aws_region             = data.aws_region.current.id
    vpc_id                 = local.selected_vpc_id
    primary_subnet_id      = local.primary_subnet_id
    secondary_subnet_id    = local.secondary_subnet_id
    secondary_private_ip   = local.is_ha_deployment ? aws_instance.mayanas_secondary[0].private_ip : ""
    subnet_cidr            = data.aws_subnet.selected.cidr_block
    # Shares configuration (fsid added by cluster_setup2.sh per node)
    shares                 = jsonencode(var.shares)
  })

  # Only primary instance needs startup script for cluster setup
}

# Primary/Node1 MayaNAS instance
resource "aws_instance" "mayanas_primary" {
  ami           = local.resolved_ami_id
  instance_type = var.instance_type
  key_name      = var.key_pair_name
  subnet_id     = local.primary_subnet_id
  availability_zone = local.primary_az
  
  # Spot instance configuration (conditional)
  dynamic "instance_market_options" {
    for_each = var.use_spot_instance ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price = var.spot_max_price != "" ? var.spot_max_price : null
        spot_instance_type = "one-time"
      }
    }
  }
  
  associate_public_ip_address = var.assign_public_ip

  vpc_security_group_ids = [aws_security_group.mayanas_sg.id]

  iam_instance_profile = var.use_iam_role ? aws_iam_instance_profile.mayanas_profile[0].name : null

  user_data_base64 = base64encode(local.startup_script_primary)
  
  # No VIP pre-assignment - Heartbeat will manage VIPs via awsIP.resource
  
  root_block_device {
    volume_type = var.boot_disk_type
    volume_size = var.boot_disk_size_gb
    encrypted   = true
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name           = var.deployment_type == "active-active" ? "${local.effective_cluster_name}-mayanas-node1" : "${local.effective_cluster_name}-primary"
    ClusterName    = local.effective_cluster_name
    DeploymentType = var.deployment_type
    NodeRole       = var.deployment_type == "active-active" ? "node1" : "primary"
  })
}

# Attach metadata disks to primary instance
resource "aws_volume_attachment" "mayanas_primary_metadata" {
  count = local.total_metadata_disk_count
  
  device_name = local.device_names[count.index] # /dev/sdf, /dev/sdg, /dev/sdh, etc.
  volume_id   = aws_ebs_volume.mayanas_metadata[count.index].id
  instance_id = aws_instance.mayanas_primary.id
  
  # Prevent termination from destroying the metadata disk
  skip_destroy = var.preserve_metadata_disk
}

# Secondary/Node2 MayaNAS instance (HA deployments only)
resource "aws_instance" "mayanas_secondary" {
  count = local.is_ha_deployment ? 1 : 0
  
  ami           = local.resolved_ami_id
  instance_type = var.instance_type
  key_name      = var.key_pair_name
  subnet_id     = local.secondary_subnet_id
  availability_zone = local.secondary_az
  
  # Spot instance configuration (conditional)
  dynamic "instance_market_options" {
    for_each = var.use_spot_instance ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price = var.spot_max_price != "" ? var.spot_max_price : null
        spot_instance_type = "one-time"
      }
    }
  }
  
  associate_public_ip_address = var.assign_public_ip

  vpc_security_group_ids = [aws_security_group.mayanas_sg.id]

  iam_instance_profile = var.use_iam_role ? aws_iam_instance_profile.mayanas_profile[0].name : null

  # No startup script - primary instance handles cluster setup
  
  # No VIP pre-assignment - Heartbeat will manage VIPs via awsIP.resource
  
  root_block_device {
    volume_type = var.boot_disk_type
    volume_size = var.boot_disk_size_gb
    encrypted   = true
    delete_on_termination = true
  }

  tags = merge(var.tags, {
    Name           = var.deployment_type == "active-active" ? "${local.effective_cluster_name}-mayanas-node2" : "${local.effective_cluster_name}-secondary"
    ClusterName    = local.effective_cluster_name
    DeploymentType = var.deployment_type
    NodeRole       = var.deployment_type == "active-active" ? "node2" : "secondary"
  })

  depends_on = [
    aws_s3_bucket.mayanas_data,
    aws_iam_role_policy_attachment.mayanas_ha_attachment[0]
  ]
}

# No metadata disks attached to secondary instance initially - primary handles cluster setup
