locals {
  subnet_map = { for subnet in var.hub.subnets : subnet.name => subnet }
}

resource "azurerm_virtual_network" "hub" {
  name                = var.hub.name
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.hub.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "hub" {
  for_each = local.subnet_map

  name                 = each.value.name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = each.value.address_prefixes
}

resource "azurerm_network_security_group" "subnet1" {
  name                = "${var.hub.name}-subnet1-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.ssh_source_address_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                         = "Allow-RFC1918-Inbound"
    priority                     = 200
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "*"
    source_port_range            = "*"
    destination_port_range       = "*"
    source_address_prefixes      = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
    destination_address_prefixes = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }
}

resource "azurerm_subnet_network_security_group_association" "subnet1" {
  subnet_id                 = azurerm_subnet.hub["subnet1"].id
  network_security_group_id = azurerm_network_security_group.subnet1.id
}

resource "azurerm_network_interface" "hub" {
  name                = "${var.hub.name}-vm-nic"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.hub["subnet1"].id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.0.4"
  }
}

resource "azurerm_linux_virtual_machine" "hub" {
  name                            = "${var.hub.name}-vm"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.hub.id]
  tags                            = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

resource "azurerm_public_ip" "bastion" {
  count = var.deploy_bastion ? 1 : 0

  name                = "${var.hub.name}-bastion-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "hub" {
  count = var.deploy_bastion ? 1 : 0

  name                = "${var.hub.name}-bastion"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.hub["AzureBastionSubnet"].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}
