output "route_server_id" {
  description = "ID of Azure Route Server."
  value       = azurerm_route_server.route_server.id
}

output "virtual_router_asn" {
  description = "Azure Route Server virtual router ASN."
  value       = azurerm_route_server.route_server.virtual_router_asn
}

output "bgp_peer_ips" {
  description = "Azure Route Server BGP peer IP addresses."
  value       = azurerm_route_server.route_server.virtual_router_ips
}
