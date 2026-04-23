# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# AWS MayaScale Terraform Module
# Composable Storage with Active-Active HA

# Generate unique suffix for resources
resource "random_id" "suffix" {
  byte_length = 4
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

# Generate random password for MayaScale instances
resource "random_password" "mayascale_password" {
  length  = 16
  special = true
  upper   = true
  lower   = true
  numeric = true
}

# Performance Policy Configurations
locals {
  policy_configs = {
    # Zonal (same-AZ) tiers - Both nodes in same availability zone
    # AWS i4i instance family (7th gen AWS Nitro SSD - validated performance)
    # Latency target: <1ms for zonal tiers
    "zonal-basic-performance" = {
      target_write_iops     = 57000    # AWS spec: 27.5K × 2 (validated: 57K)
      target_read_iops      = 200000   # AWS spec: 50K × 2 (validated: 204K, rounded to 200K)
      target_write_latency  = 1000     # <1ms (Validated: 0.561ms optimal, 0.169ms QD1)
      target_bandwidth_mbps = 1200     # Validated: 1,182 MB/s seq read, 546 MB/s seq write
      availability_strategy = "same-az"
      capacity_optimization = "cost"
      instance_type        = "i4i.xlarge"  # AWS Nitro SSD, up to 10 Gbps network (1.875 baseline)
      nvme_device_count    = 1
      nvme_capacity_gb     = 937       # i4i.xlarge has 937GB NVMe
    }

    "zonal-standard-performance" = {
      target_write_iops     = 135000   # AWS spec: 130K (validated: 135K)
      target_read_iops      = 346000   # AWS spec: 170K × 2 (validated: 346K)
      target_write_latency  = 1000     # <1ms
      target_bandwidth_mbps = 3000
      availability_strategy = "same-az"
      capacity_optimization = "cost"
      instance_type        = "i3en.2xlarge"  # 8 vCPU, 2 x 2.5TB NVMe, up to 25 Gbps (8.4 baseline)
      nvme_device_count    = 2         # 2 SSDs = 2 NVMe-oF volumes
      nvme_capacity_gb     = 5000      # Total: 2 x 2.5TB = 5TB
    }

    "zonal-high-performance" = {
      target_write_iops     = 400000   # AWS spec: 400K (after initialization)
      target_read_iops      = 992000   # AWS spec: 500K × ~2.0 (validated: 992K)
      target_write_latency  = 1000     # <1ms (150µs target)
      target_bandwidth_mbps = 8000
      availability_strategy = "same-az"
      capacity_optimization = "balanced"
      instance_type        = "i3en.6xlarge"  # 24 vCPU, 2 x 7.5TB NVMe, 25 Gbps sustained
      nvme_device_count    = 2         # 2 SSDs = 2 NVMe-oF volumes (Active-Active)
      nvme_capacity_gb     = 15000     # Total: 2 x 7.5TB = 15TB
    }

    "zonal-ultra-performance" = {
      target_write_iops     = 528000   # Validated: 528K (Nov 1, 2025) - AWS i3en NVMe limited
      target_read_iops      = 1350000  # Validated: 1.35M (Nov 1, 2025)
      target_write_latency  = 1000     # <1ms (250-600µs typical)
      target_bandwidth_mbps = 8240     # 2.06 GB/s write + 5.27 GB/s read
      availability_strategy = "same-az"
      capacity_optimization = "performance"
      instance_type        = "i3en.12xlarge"  # 48 vCPU, 4 x 7.5TB NVMe, 50 Gbps sustained
      nvme_device_count    = 4         # 4 SSDs = 4 NVMe-oF volumes (Active-Active)
      nvme_capacity_gb     = 30000     # Total: 4 x 7.5TB = 30TB
      # Note: 800K target impossible - raw NVMe only delivers 635K (79% of AWS spec)
      # Bottleneck: AWS i3en NVMe queue depth sensitivity, NOT network or CPU
    }

    # Regional (cross-AZ) tiers - HA across availability zones
    # Write IOPS: 0.90× zonal (cross-AZ RAID1 sync overhead)
    # Read IOPS: Same as zonal (client reads from same-AZ node)
    # Latency target: <2ms for regional tiers (cross-AZ sync adds ~700µs)
    "regional-basic-performance" = {
      target_write_iops     = 50000    # 57K × 0.90 = 51K (rounded to 50K for marketing)
      target_read_iops      = 200000   # 204K (rounded to 200K for marketing)
      target_write_latency  = 2000     # <2ms (cross-AZ sync adds ~700µs vs zonal <1ms)
      target_bandwidth_mbps = 1200     # Same as zonal
      availability_strategy = "cross-az"
      capacity_optimization = "cost"
      instance_type        = "i4i.xlarge"  # AWS Nitro SSD, up to 10 Gbps (1.875 baseline)
      nvme_device_count    = 1
      nvme_capacity_gb     = 937
    }

    "regional-standard-performance" = {
      target_write_iops     = 120000   # 135K × 0.90 = 122K (rounded to 120K for marketing)
      target_read_iops      = 350000   # 346K (rounded to 350K for marketing)
      target_write_latency  = 2000     # <2ms (cross-AZ sync adds ~700µs vs zonal <1ms)
      target_bandwidth_mbps = 3000
      availability_strategy = "cross-az"
      capacity_optimization = "cost"
      instance_type        = "i3en.2xlarge"  # 8 vCPU, 2 x 2.5TB NVMe, up to 25 Gbps (8.4 baseline)
      nvme_device_count    = 2         # 2 SSDs = 2 NVMe-oF volumes
      nvme_capacity_gb     = 5000      # Total: 2 x 2.5TB = 5TB
    }

    "regional-high-performance" = {
      target_write_iops     = 330000   # 368K × 0.90 = 331K (rounded to 330K for marketing)
      target_read_iops      = 1000000  # 992K (rounded to 1M for marketing)
      target_write_latency  = 2000     # <2ms (cross-AZ sync adds ~700µs)
      target_bandwidth_mbps = 8000
      availability_strategy = "cross-az"
      capacity_optimization = "balanced"
      instance_type        = "i3en.6xlarge"  # 24 vCPU, 2 x 7.5TB NVMe, 25 Gbps sustained
      nvme_device_count    = 2         # 2 SSDs = 2 NVMe-oF volumes (Active-Active)
      nvme_capacity_gb     = 15000     # Total: 2 x 7.5TB = 15TB
    }

    "regional-ultra-performance" = {
      target_write_iops     = 475000   # 528K × 0.90 (cross-AZ RAID1 sync overhead) - Validated
      target_read_iops      = 1350000  # Same as zonal (client reads from same-AZ Node1) - Validated
      target_write_latency  = 2000     # <2ms (cross-AZ sync adds ~700µs)
      target_bandwidth_mbps = 8240     # Same as zonal
      availability_strategy = "cross-az"
      capacity_optimization = "performance"
      instance_type        = "i3en.12xlarge"  # 48 vCPU, 4 x 7.5TB NVMe, 50 Gbps sustained
      nvme_device_count    = 4         # 4 SSDs = 4 NVMe-oF volumes (Active-Active)
      nvme_capacity_gb     = 30000     # Total: 4 x 7.5TB = 30TB
      # Note: Based on validated 528K zonal performance (Nov 1, 2025)
    }
  }

  # Active policy configuration
  selected_policy = local.policy_configs[var.performance_policy]

  # vCPU mapping for AWS instance types
  vcpu_map = {
    "i4i.xlarge"      = 4
    "i3.large"        = 2
    "i3en.2xlarge"    = 8
    "i3en.6xlarge"    = 24
    "i3en.12xlarge"   = 48
  }

  # Cluster naming
  cluster_name = var.cluster_name != "" ? var.cluster_name : "mayascale-${random_id.suffix.hex}"

  # Instance type selection (user override or auto-selected from performance policy)
  selected_instance_type = var.instance_type_override != "" ? var.instance_type_override : local.selected_policy.instance_type

  # Availability zone strategy
  node1_az = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]

  # For cross-AZ: find first subnet in a different AZ from node1
  # For same-AZ: use same AZ as node1
  available_secondary_azs = local.selected_policy.availability_strategy == "same-az" ? [local.node1_az] : [
    for s in data.aws_subnets.default.ids :
    data.aws_subnet.by_id[s].availability_zone
    if data.aws_subnet.by_id[s].availability_zone != local.node1_az
  ]

  node2_az = length(local.available_secondary_azs) > 0 ? local.available_secondary_azs[0] : local.node1_az

  # VIP calculation (auto-calculate from subnet CIDR with random offsets)
  # Use random offsets to avoid VIP conflicts between multiple HA pairs
  # Random value derived from random_id.suffix (4 bytes = up to 4 billion)
  full_random_value = tonumber(format("%d", random_id.suffix.dec))
  vip_offset1 = (local.full_random_value % 200) + 50       # Range: 50-249 (avoid low IPs used by AWS)
  vip_offset2 = floor(local.full_random_value / 256) % 200 + 50
  vip_address   = cidrhost(data.aws_subnet.primary.cidr_block, local.vip_offset1)
  vip_address_2 = cidrhost(data.aws_subnet.primary.cidr_block, local.vip_offset2)

  # Backend network IPs for replication traffic
  # Zonal: 10.200.0.10 and 10.200.0.11 in /24
  # Regional: 10.200.0.10 in /25 subnet1, 10.200.0.138 in /25 subnet2
  backend_node1_ip = cidrhost("10.200.0.0/24", 10)  # 10.200.0.10 (works for both /24 and /25)
  backend_node2_ip = local.selected_policy.availability_strategy == "same-az" ? cidrhost("10.200.0.0/24", 11) : cidrhost("10.200.0.128/25", 10)  # 10.200.0.11 (zonal) or 10.200.0.138 (regional)

  # Tags
  common_tags = {
    Application        = "mayascale"
    ManagedBy         = "terraform"
    DeploymentName    = local.cluster_name
    PerformancePolicy = var.performance_policy
    AvailabilityStrategy = local.selected_policy.availability_strategy
    CostTier          = local.selected_policy.capacity_optimization
  }
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Get primary subnet (in node1 AZ)
data "aws_subnet" "primary" {
  id = element([for s in data.aws_subnets.default.ids : s
    if data.aws_subnet.by_id[s].availability_zone == local.node1_az], 0)
}

# Get secondary subnet (in node2 AZ for cross-AZ, same as primary for same-AZ)
data "aws_subnet" "secondary" {
  id = element([for s in data.aws_subnets.default.ids : s
    if data.aws_subnet.by_id[s].availability_zone == local.node2_az], 0)
}

data "aws_subnet" "by_id" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

# Get latest AMI from AWS Marketplace using product code
data "aws_ami" "mayascale_marketplace" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["aws-marketplace"]

  filter {
    name   = "product-code"
    values = [var.mayascale_product_code]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : (
    length(data.aws_ami.mayascale_marketplace) > 0 ? data.aws_ami.mayascale_marketplace[0].id : ""
  )
}

# IAM Role for MayaScale instances
resource "aws_iam_role" "mayascale_role" {
  name = "${local.cluster_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.common_tags
}

# IAM policy for EC2 operations (for HA failover and STONITH fencing)
resource "aws_iam_role_policy" "mayascale_ec2_policy" {
  name = "${local.cluster_name}-ec2-policy"
  role = aws_iam_role.mayascale_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
      }
    ]
  })
}

resource "aws_iam_instance_profile" "mayascale_profile" {
  name = "${local.cluster_name}-instance-profile"
  role = aws_iam_role.mayascale_role.name

  tags = local.common_tags
}

# Security Group
resource "aws_security_group" "mayascale_sg" {
  name        = "${local.cluster_name}-sg"
  description = "Security group for MayaScale cluster"
  vpc_id      = data.aws_vpc.default.id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
    description = "SSH access"
  }

  # Web UI (management interface)
  ingress {
    from_port   = 2020
    to_port     = 2020
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
    description = "Web UI access from external"
  }

  # NVMe-oF (client access)
  ingress {
    from_port   = var.client_nvme_port
    to_port     = var.client_nvme_port + 16
    protocol    = "tcp"
    cidr_blocks = var.client_access_control
    description = "NVMe-oF client access"
  }

  # iSCSI (client access)
  ingress {
    from_port   = var.client_iscsi_port
    to_port     = var.client_iscsi_port
    protocol    = "tcp"
    cidr_blocks = var.client_access_control
    description = "iSCSI client access"
  }

  # All traffic from VPC (matches CloudFormation behavior)
  # Allows clients anywhere in VPC to access NVMe-oF, web UI, and all cluster services
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
    description = "All traffic from VPC (NVMe-oF and all other services for clients)"
  }

  # Internal cluster communication (between nodes in same security group)
  ingress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    self      = true
    description = "Internal cluster communication"
  }

  # All outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(local.common_tags, {
    Name = "${local.cluster_name}-sg"
  })
}

# Placement Group for same-AZ deployments (co-location)
resource "aws_placement_group" "mayascale_pg" {
  count    = local.selected_policy.availability_strategy == "same-az" ? 1 : 0
  name     = "${local.cluster_name}-pg"
  strategy = "cluster"

  tags = local.common_tags
}

# Network Interfaces for VIP management
# Note: Primary ENIs are auto-created by AWS when instances are created with subnet_id
# This allows AWS to automatically assign public IPs (like CloudFormation does)

# Backend Network Infrastructure for Replication Traffic
# Separate VPC for dedicated replication traffic (isolated from client traffic)
resource "aws_vpc" "backend" {
  cidr_block           = "10.200.0.0/24"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name    = "${local.cluster_name}-backend-vpc"
    Purpose = "MayaScale replication traffic"
  })
}

# Route table for backend VPC (only for cross-AZ deployments)
# Zonal deployments use the VPC's default main route table
resource "aws_route_table" "backend" {
  count  = local.selected_policy.availability_strategy == "cross-az" ? 1 : 0
  vpc_id = aws_vpc.backend.id

  # AWS automatically adds local route: 10.200.0.0/24 → local
  # This enables cross-subnet communication within the VPC

  tags = merge(local.common_tags, {
    Name    = "${local.cluster_name}-backend-route-table"
    Purpose = "Backend replication traffic routing"
  })
}

# Associate route table with backend node1 subnet (cross-AZ only)
resource "aws_route_table_association" "backend_node1" {
  count          = local.selected_policy.availability_strategy == "cross-az" ? 1 : 0
  subnet_id      = aws_subnet.backend_node1.id
  route_table_id = aws_route_table.backend[0].id
}

# Associate route table with backend node2 subnet (cross-AZ only)
resource "aws_route_table_association" "backend_node2" {
  count          = local.selected_policy.availability_strategy == "cross-az" ? 1 : 0
  subnet_id      = aws_subnet.backend_node2[0].id
  route_table_id = aws_route_table.backend[0].id
}

# Backend subnets - conditional based on deployment type
# Zonal (same-AZ): Single /24 subnet in node1 AZ, both nodes attach
# Regional (cross-AZ): Two /25 subnets, one per AZ for better fault isolation

# Backend subnet for node1 (always created)
resource "aws_subnet" "backend_node1" {
  vpc_id            = aws_vpc.backend.id
  cidr_block        = local.selected_policy.availability_strategy == "same-az" ? "10.200.0.0/24" : "10.200.0.0/25"
  availability_zone = local.node1_az

  tags = merge(local.common_tags, {
    Name    = "${local.cluster_name}-backend-subnet-node1"
    Purpose = "MayaScale replication traffic - Node1"
  })
}

# Backend subnet for node2 (only for cross-AZ, shares node1 subnet for same-AZ)
resource "aws_subnet" "backend_node2" {
  count             = local.selected_policy.availability_strategy == "cross-az" ? 1 : 0
  vpc_id            = aws_vpc.backend.id
  cidr_block        = "10.200.0.128/25"
  availability_zone = local.node2_az

  tags = merge(local.common_tags, {
    Name    = "${local.cluster_name}-backend-subnet-node2"
    Purpose = "MayaScale replication traffic - Node2"
  })
}

# Backend security group (allow all traffic within backend network)
resource "aws_security_group" "backend_sg" {
  name        = "${local.cluster_name}-backend-sg"
  description = "Security group for MayaScale backend replication traffic"
  vpc_id      = aws_vpc.backend.id

  # Allow all traffic within backend network
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.200.0.0/24"]
    description = "All traffic within backend network"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.200.0.0/24"]
    description = "All traffic within backend network"
  }

  tags = merge(local.common_tags, {
    Name    = "${local.cluster_name}-backend-sg"
    Purpose = "Backend replication traffic"
  })
}

# Node1 backend network interface
resource "aws_network_interface" "node1_backend" {
  subnet_id       = aws_subnet.backend_node1.id
  security_groups = [aws_security_group.backend_sg.id]
  private_ips     = [local.backend_node1_ip]

  tags = merge(local.common_tags, {
    Name    = "${local.cluster_name}-node1-backend-eni"
    Node    = "node1"
    Purpose = "Backend replication"
  })
}

# Node2 backend network interface
# Zonal: uses same subnet as node1 (backend_node1)
# Regional: uses separate subnet in node2's AZ (backend_node2)
resource "aws_network_interface" "node2_backend" {
  subnet_id       = local.selected_policy.availability_strategy == "same-az" ? aws_subnet.backend_node1.id : aws_subnet.backend_node2[0].id
  security_groups = [aws_security_group.backend_sg.id]
  private_ips     = [local.backend_node2_ip]

  tags = merge(local.common_tags, {
    Name    = "${local.cluster_name}-node2-backend-eni"
    Node    = "node2"
    Purpose = "Backend replication"
  })
}


# Startup script for Node1 (defined in locals to avoid circular dependency)
locals {
  startup_script_node1 = templatefile("${path.module}/startup-cluster.sh.tpl", {
    cluster_name           = local.cluster_name
    deployment_type        = var.deployment_type
    node_role              = "node1"
    vip_address            = local.vip_address
    vip_address_2          = local.vip_address_2
    performance_policy     = var.performance_policy
    peer_zone              = local.node2_az
    resource_id            = random_integer.resource_id.result
    peer_resource_id       = random_integer.peer_resource_id.result
    nvme_count             = local.selected_policy.nvme_device_count
    # Secondary instance IPs (Terraform will create node2 first due to this dependency)
    secondary_private_ip   = aws_instance.mayascale_node2.private_ip
    secondary_backend_ip   = local.backend_node2_ip
    secondary_instance_id  = aws_instance.mayascale_node2.id
    secondary_hostname     = aws_instance.mayascale_node2.private_dns
    # Primary backend IP (passed directly like CloudFormation - no circular dependency)
    primary_backend_ip     = local.backend_node1_ip
    # Backend network configuration for cross-AZ
    is_cross_az            = local.selected_policy.availability_strategy == "cross-az"
    # Client export configuration
    client_nvme_port       = var.client_nvme_port
    client_iscsi_port      = var.client_iscsi_port
    client_protocol        = var.client_protocol
    client_exports_enabled = var.client_exports_enabled
    # Share configuration
    shares                = jsonencode(var.shares)
    # Startup wait configuration
    mayascale_startup_wait = var.mayascale_startup_wait != null ? tostring(var.mayascale_startup_wait) : ""
  })
}

# Node2 MayaScale Storage Instance (created first, no startup script)
resource "aws_instance" "mayascale_node2" {
  ami                  = local.ami_id
  instance_type        = local.selected_instance_type
  key_name             = var.key_pair_name
  iam_instance_profile = aws_iam_instance_profile.mayascale_profile.name
  availability_zone    = local.node2_az

  # Use subnet_id to let AWS auto-create primary ENI (like CloudFormation/MayaNAS)
  # For cross-AZ: use secondary subnet (in different AZ). For same-AZ: same as primary
  subnet_id                   = data.aws_subnet.secondary.id
  vpc_security_group_ids      = [aws_security_group.mayascale_sg.id]
  associate_public_ip_address = var.assign_public_ip

  # Placement group only for same-AZ AND on-demand instances
  # Spot instances are excluded to avoid complexity with instance replacements
  placement_group = (local.selected_policy.availability_strategy == "same-az") ? aws_placement_group.mayascale_pg[0].id : null

  # EBS root volume
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Spot instance configuration (optional)
  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type = "one-time"
        # No instance_interruption_behavior - defaults to "terminate" (compatible with one-time)
      }
    }
  }

  # Minimal startup script for node2 - add route to node1 subnet via gateway for cross-AZ
  user_data_base64 = local.selected_policy.availability_strategy == "cross-az" ? base64encode(<<-EOF
    #!/bin/bash
    # Wait for eth1 DHCP configuration (AWS assigns /25)
    for i in {1..30}; do ip addr show dev eth1 2>/dev/null | grep -q "inet.*\/25" && break || sleep 2; done
    # Add route to node1's /25 subnet via VPC gateway
    # Node2 (10.200.0.128/25) needs route to 10.200.0.0/25 via 10.200.0.129
    ip route add 10.200.0.0/25 via 10.200.0.129 dev eth1 || true
    EOF
  ) : null

  tags = merge(local.common_tags, {
    Name      = "${local.cluster_name}-node2"
    Cluster   = local.cluster_name
    NodeRole  = "secondary"
    NodeIndex = "2"
  })

  depends_on = [
    aws_iam_role_policy.mayascale_ec2_policy
  ]
}

# Node1 MayaScale Storage Instance (created second, references node2)
resource "aws_instance" "mayascale_node1" {
  ami                  = local.ami_id
  instance_type        = local.selected_instance_type
  key_name             = var.key_pair_name
  iam_instance_profile = aws_iam_instance_profile.mayascale_profile.name
  availability_zone    = local.node1_az

  # Use subnet_id to let AWS auto-create primary ENI (like CloudFormation/MayaNAS)
  subnet_id                   = data.aws_subnet.primary.id
  vpc_security_group_ids      = [aws_security_group.mayascale_sg.id]
  associate_public_ip_address = var.assign_public_ip

  # VIPs are NOT pre-assigned (CloudFormation pattern)
  # VIPs are managed dynamically by Pacemaker awsIP resource agent via AWS API
  # Pre-assigning VIPs causes conflict: awsIP tries to create eth0:0 alias but IP already exists on eth0
  # secondary_private_ips = [local.vip_address, local.vip_address_2]  # REMOVED

  # Placement group only for same-AZ AND on-demand instances
  # Spot instances are excluded to avoid complexity with instance replacements
  placement_group = (local.selected_policy.availability_strategy == "same-az") ? aws_placement_group.mayascale_pg[0].id : null

  # EBS root volume
  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Spot instance configuration (optional)
  dynamic "instance_market_options" {
    for_each = var.use_spot_instances ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type = "one-time"
        # No instance_interruption_behavior - defaults to "terminate" (compatible with one-time)
      }
    }
  }

  # Startup script for cluster initialization
  user_data_base64 = base64encode(local.startup_script_node1)

  tags = merge(local.common_tags, {
    Name      = "${local.cluster_name}-node1"
    Cluster   = local.cluster_name
    NodeRole  = "primary"
    NodeIndex = "1"
  })

  depends_on = [
    aws_iam_role_policy.mayascale_ec2_policy,
    aws_instance.mayascale_node2  # Explicit dependency - node2 must exist first
  ]
}

# Attach backend ENIs to instances after creation (device_index 1)
resource "aws_network_interface_attachment" "node1_backend" {
  instance_id          = aws_instance.mayascale_node1.id
  network_interface_id = aws_network_interface.node1_backend.id
  device_index         = 1
}

resource "aws_network_interface_attachment" "node2_backend" {
  instance_id          = aws_instance.mayascale_node2.id
  network_interface_id = aws_network_interface.node2_backend.id
  device_index         = 1
}
