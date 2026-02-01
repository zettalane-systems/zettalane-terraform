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

resource "azurerm_public_ip" "client" {
  name                = "${var.client_name}-pip"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
}

resource "azurerm_network_interface" "client" {
  name                = "${var.client_name}-nic"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = var.resource_group_name

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

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  priority        = var.use_spot ? "Spot" : "Regular"
  eviction_policy = var.use_spot ? "Deallocate" : null

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    ssh_public_key = var.ssh_public_key
    admin_username = var.admin_username
  }))
}
