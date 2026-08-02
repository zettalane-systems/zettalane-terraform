# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Azure Lattice pNFS Metadata Server (MDS) Module
#
# Single VM that runs the Lattice user-space pNFS metadata
# server plus a co-located single-node RonDB (ndb_mgmd + ndbmtd,
# NoOfReplicas=1). The data servers are EXTERNAL — two MayaNAS active-active
# VIP/NFS shares wired in via setup-lattice-mds.sh (ds[0]/ds[1]).
#
# For the HA variant (2 data nodes on their own VMs) scale this out later;
# this module is the smoke/kick-the-tires single-box MDS. Azure port of
# gcp/lattice-mds — same guest, same setup script, different plumbing.

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "core"
  features {}
}

data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_subnet" "main" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

# ---------------------------------------------------------------------------
# MDS image selection: the prebuilt lattice-mds community image, probed rather
# than set as a default because it is replicated per region independently of
# this module, so a hard default would break deploys elsewhere.
# The image carries pnfs-mds, mds-admin and /opt/rondb, and setup-lattice-mds.sh
# only CONFIGURES an MDS -- there is no build path -- so the image is required
# and a failed probe is a hard error, enforced by the precondition below.
# RonDB is left uninitialised in the image so ds_registry seeds from the
# mds.conf written at deploy time.
# ---------------------------------------------------------------------------
data "external" "mds_image" {
  count = var.mds_image_id == "" ? 1 : 0
  program = ["bash", "-c", <<-EOF
    if az sig image-definition show-community \
         --public-gallery-name "${var.mds_community_gallery}" \
         --gallery-image-definition "${var.mds_image_definition}" \
         --location "${data.azurerm_resource_group.main.location}" \
         --query name -o tsv >/dev/null 2>&1; then
      echo '{"id":"/communityGalleries/${var.mds_community_gallery}/images/${var.mds_image_definition}"}'
    else
      echo '{"id":""}'
    fi
  EOF
  ]
}

locals {
  # Explicit override wins; else whatever the probe found.
  mds_image_id = var.mds_image_id != "" ? var.mds_image_id : try(data.external.mds_image[0].result.id, "")
}

resource "azurerm_public_ip" "mds" {
  name                = "${var.mds_name}-pip"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "mds" {
  name                           = "${var.mds_name}-nic"
  location                       = data.azurerm_resource_group.main.location
  resource_group_name            = var.resource_group_name
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.mds.id
  }
}

# SSH from wherever you administer; NFS/rpcbind/RonDB stay inside the VNet.
# 2049 is how clients mount pNFS (the MDS serves the metadata path); 1186 is
# RonDB's management port, local today but VNet-scoped so the HA variant can
# reach it without reopening this.
resource "azurerm_network_security_group" "mds" {
  name                = "${var.mds_name}-nsg"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.ssh_cidr_blocks
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "pNFS"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["111", "2049"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "RonDB"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1186"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "mds" {
  network_interface_id      = azurerm_network_interface.mds.id
  network_security_group_id = azurerm_network_security_group.mds.id
}

resource "azurerm_linux_virtual_machine" "mds" {
  name                = var.mds_name
  location            = data.azurerm_resource_group.main.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username

  proximity_placement_group_id = var.proximity_placement_group_id != "" ? var.proximity_placement_group_id : null

  network_interface_ids = [azurerm_network_interface.mds.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  # Holds the RonDB DataDir (redo + local checkpoints) and the pnfs-lattice
  # build tree. Premium_LRS because redo writes are latency-sensitive.
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.boot_disk_gb
  }

  source_image_id = local.mds_image_id

  # A stock image would boot fine and then fail minutes later inside
  # setup-lattice-mds.sh on a missing-binary check. Refuse here instead, where
  # the message can name the gallery and region that were searched.
  lifecycle {
    precondition {
      condition     = local.mds_image_id != ""
      error_message = "MDS image ${var.mds_image_definition} is not available in ${data.azurerm_resource_group.main.location}."
    }
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = var.ssh_public_key
    admin_username = var.admin_username
  }))

  # Spot: Deallocate rather than Delete so the disk (and the built Lattice tree)
  # survives an eviction and the VM can simply be restarted. max_bid_price = -1
  # means "pay up to the on-demand price", i.e. only evict on capacity.
  priority        = var.use_spot ? "Spot" : "Regular"
  eviction_policy = var.use_spot ? "Deallocate" : null
  max_bid_price   = var.use_spot ? -1 : null
}
