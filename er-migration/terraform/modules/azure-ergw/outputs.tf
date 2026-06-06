output "circuit_id" {
  description = "Resource ID of the ExpressRoute circuit."
  value       = azurerm_express_route_circuit.this.id
}

output "circuit_service_key" {
  description = "Service key used by Megaport to provision the ExpressRoute VXC."
  value       = azurerm_express_route_circuit.this.service_key
  sensitive   = true
}

output "original_gateway_id" {
  description = "Resource ID of the original ExpressRoute virtual network gateway."
  value       = azurerm_virtual_network_gateway.gateway["original"].id
}

output "migrated_gateway_id" {
  description = "Resource ID of the migrated ExpressRoute virtual network gateway."
  value       = azurerm_virtual_network_gateway.gateway["migrated"].id
}
