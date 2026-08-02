# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# AWS Lattice pNFS Metadata Server (MDS) Module
#
# Single EC2 instance running the Lattice user-space pNFS metadata server
# plus a co-located single-node RonDB (ndb_mgmd + ndbmtd,
# NoOfReplicas=1). The data servers are EXTERNAL -- two MayaNAS active-active
# VIP/NFS shares wired in via setup-lattice-mds.sh (ds[0]/ds[1]).
#
# For the HA variant (2 data nodes on their own instances) scale this out
# later; this module is the smoke/kick-the-tires single-box MDS.

provider "aws" {
  region = var.region
}

# Fall back to the account default VPC only when the caller passes nothing.
# A real pNFS deploy always passes the MayaNAS VPC, because the DS VIPs are
# secondary private addresses inside the storage subnet and are unreachable
# from anywhere else.
data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "fallback" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }

  # Pin the AZ when one is given so the MDS lands beside the data servers.
  dynamic "filter" {
    for_each = var.availability_zone != "" ? [1] : []
    content {
      name   = "availability-zone"
      values = [var.availability_zone]
    }
  }
}

data "aws_vpc" "selected" {
  id = local.vpc_id
}

# aws_ami_ids returns an EMPTY LIST when nothing matches, where aws_ami fails
# the plan outright. The empty list is what lets the precondition on the
# instance below report a missing image in its own words, naming the filter
# that was searched, instead of surfacing a provider-level lookup error.
data "aws_ami_ids" "lattice_mds" {
  count  = var.source_ami == "" ? 1 : 0
  owners = var.image_owners

  filter {
    name   = "name"
    values = [var.source_ami_name_filter]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  vpc_id    = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
  subnet_id = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.fallback[0].ids[0]

  # try(), not a length() guard: with source_ami set the data source has count = 0, and
  # terraform evaluates the [0] index EAGERLY -- a && in front of it does not short-circuit
  # the way it reads. try() covers both that empty tuple and an empty ids list.
  # aws_ami_ids returns newest first, so element 0 is the latest publish.
  discovered_ami = try(data.aws_ami_ids.lattice_mds[0].ids[0], "")
  ami_id         = var.source_ami != "" ? var.source_ami : local.discovered_ami
}

resource "aws_security_group" "mds" {
  name        = "${var.mds_name}-sg"
  description = "Lattice pNFS MDS: SSH in, unrestricted inside the VPC"
  vpc_id      = local.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  # One rule instead of an enumerated port list. The MDS both serves (2049 to
  # clients) and consumes (2049 plus the portmapper/statd ports on the DS
  # VIPs), and RonDB's mgmd/data-node ports are dynamic. Enumerating them
  # invites a silent NFS4ERR on a port nobody thought to open, and the blast
  # radius is one VPC that already holds only this cluster.
  ingress {
    description = "All traffic within the VPC (pNFS to clients, NFS to the DS, RonDB)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.mds_name}-sg"
    Product = "lattice-mds"
  }
}

resource "aws_instance" "mds" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.mds.id]
  key_name                    = var.key_pair_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.boot_disk_gb
    volume_type = "gp3"
    encrypted   = true
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
    }
  }

  # There is no build-from-source path: setup-lattice-mds.sh only CONFIGURES an MDS and
  # gates on pnfs-mds/mds-admin/lattice-genconfig already being present. A stock image
  # would therefore boot fine and fail minutes later on a prerequisite check, so refuse
  # here instead, while the message can still name the cause.
  lifecycle {
    precondition {
      condition     = local.ami_id != ""
      error_message = "MDS image ${var.source_ami_name_filter} is not available in ${var.region}."
    }
  }

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = var.ssh_public_key
    admin_username = var.admin_username
  })

  tags = {
    Name    = var.mds_name
    Product = "lattice-mds"
    Role    = "pnfs-metadata-server"
  }
}
