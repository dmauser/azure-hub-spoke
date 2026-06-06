output "vnet_id" {
  description = "ID of the spoke virtual network."
  value       = azurerm_virtual_network.spoke.id
}

output "vnet_name" {
  description = "Name of the spoke virtual network."
  value       = azurerm_virtual_network.spoke.name
}
