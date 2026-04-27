# Copyright (c) 2026 ZettaLane Systems, LLC.
# All Rights Reserved.

# Azure Client Testing Module - Ubuntu Client for NFS Testing

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "core"
  features {}
}

data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  resource_group_name = var.resource_group_name
}

data "azurerm_subnet" "main" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.resource_group_name
}

# Auto-accept Marketplace plan terms for images that require it (Rocky/RESF,
# RedHat, SUSE, etc.). Canonical's free Ubuntu images don't carry plan
# information, so attempting to accept terms for them errors with "no plans
# found"; skip the resource entirely for Canonical. Other free-tier
# publishers without plans can be added to the exclusion list as needed.
locals {
  needs_plan = !contains(["Canonical"], var.source_image_publisher)
}

resource "azurerm_marketplace_agreement" "client_image" {
  count     = local.needs_plan ? 1 : 0
  publisher = var.source_image_publisher
  offer     = var.source_image_offer
  plan      = var.source_image_sku
}

resource "azurerm_public_ip" "client" {
  name                = "${var.client_name}-pip"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
}

resource "azurerm_network_interface" "client" {
  name                           = "${var.client_name}-nic"
  location                       = data.azurerm_resource_group.main.location
  resource_group_name            = var.resource_group_name
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.client.id
  }
}

resource "azurerm_network_security_group" "client" {
  name                = "${var.client_name}-nsg"
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
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "client" {
  network_interface_id      = azurerm_network_interface.client.id
  network_security_group_id = azurerm_network_security_group.client.id
}

resource "azurerm_linux_virtual_machine" "client" {
  name                = var.client_name
  location            = data.azurerm_resource_group.main.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = var.admin_username

  proximity_placement_group_id = var.proximity_placement_group_id != "" ? var.proximity_placement_group_id : null

  network_interface_ids = [azurerm_network_interface.client.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  # Rocky Linux 9 (resf publisher) — chosen because Whamcloud's Lustre 2.17
  # DKMS package builds cleanly against its kernel. Override per-deployment
  # via the source_image_* variables if you need Ubuntu / RHEL / etc.
  source_image_reference {
    publisher = var.source_image_publisher
    offer     = var.source_image_offer
    sku       = var.source_image_sku
    version   = var.source_image_version
  }

  # Marketplace plan info — required by Azure when source_image_reference
  # points at any Marketplace image with plan info (RESF Rocky, RedHat, SUSE).
  # Canonical's free Ubuntu images don't carry plan info, so the block must
  # be omitted in that case (passing publisher="Canonical" here errors with
  # "Plan information is not allowed").
  dynamic "plan" {
    for_each = local.needs_plan ? [1] : []
    content {
      publisher = var.source_image_publisher
      product   = var.source_image_offer
      name      = var.source_image_sku
    }
  }

  priority        = var.use_spot ? "Spot" : "Regular"
  eviction_policy = var.use_spot ? "Deallocate" : null

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = var.ssh_public_key
    admin_username = var.admin_username
  }))

  # depends_on only matters when the agreement resource is created (count=1).
  # When count=0 the list is empty and depends_on is a no-op.
  depends_on = [
    azurerm_marketplace_agreement.client_image,
  ]
}
