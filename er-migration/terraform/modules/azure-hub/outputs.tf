output "vnet_id" {
  description = "ID of the hub virtual network."
  value       = azurerm_virtual_network.hub.id
}

output "vnet_name" {
  description = "Name of the hub virtual network."
  value       = azurerm_virtual_network.hub.name
}

output "resource_group_name" {
  description = "Resource group name passed to the hub module."
  value       = var.resource_group_name
}

output "gateway_subnet_id" {
  description = "ID of GatewaySubnet."
  value       = azurerm_subnet.hub["GatewaySubnet"].id
}

output "subnet_ids" {
  description = "Map of hub subnet names to subnet IDs."
  value       = { for name, subnet in azurerm_subnet.hub : name => subnet.id }
}
