resource "azurerm_public_ip" "route_server" {
  name                = "az-route-server-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_route_server" "route_server" {
  name                             = "az-route-server"
  resource_group_name              = var.resource_group_name
  location                         = var.location
  sku                              = "Standard"
  public_ip_address_id             = azurerm_public_ip.route_server.id
  subnet_id                        = var.route_server_subnet_id
  branch_to_branch_traffic_enabled = var.branch_to_branch
  tags                             = var.tags
}
