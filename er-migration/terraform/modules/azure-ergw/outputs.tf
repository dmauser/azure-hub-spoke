output "circuit_id" {
  description = "Resource ID of the ExpressRoute circuit."
  value       = azurerm_express_route_circuit.this.id
}

output "circuit_service_key" {
  description = "Service key used by Megaport to provision the ExpressRoute VXC."
  value       = azurerm_express_route_circuit.this.service_key
  sensitive   = true
}

output "gateway_id" {
  description = "Resource ID of the ExpressRoute virtual network gateway."
  value       = azurerm_virtual_network_gateway.gateway.id
}
