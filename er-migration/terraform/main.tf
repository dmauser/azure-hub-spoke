resource "azurerm_resource_group" "main" {
  name     = var.rg_name
  location = var.location
  tags     = local.common_tags
}

module "hub" {
  source = "./modules/azure-hub"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags

  hub            = var.hub
  admin_username = var.admin_username
  admin_password = var.admin_password
  vm_size        = var.vm_size
  deploy_bastion = var.deploy_bastion
}

module "spokes" {
  source   = "./modules/azure-spoke"
  for_each = var.spokes

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags

  name                    = each.value.name
  address_space           = each.value.address_space
  subnets                 = each.value.subnets
  vm_size                 = var.vm_size
  admin_username          = var.admin_username
  admin_password          = var.admin_password
  hub_vnet_id             = module.hub.vnet_id
  hub_vnet_name           = module.hub.vnet_name
  hub_resource_group_name = azurerm_resource_group.main.name
}

module "ergw" {
  source = "./modules/azure-ergw"

  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = local.common_tags

  gateway_subnet_id = module.hub.gateway_subnet_id
  er_gateway        = var.er_gateway
  er_circuit        = var.er_circuit
}

module "gcp_onprem" {
  source = "./modules/gcp-onprem"
  count  = var.gcp_onprem.deploy_gcp ? 1 : 0

  gcp_onprem = var.gcp_onprem
  project    = var.gcp_project
  region     = var.gcp_region
  zone       = var.gcp_zone
}
