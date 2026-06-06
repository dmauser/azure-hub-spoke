output "resource_group_name" {
  description = "Azure resource group name for the ER migration lab."
  value       = azurerm_resource_group.main.name
}

output "hub_vnet_id" {
  description = "Hub virtual network resource ID."
  value       = module.hub.vnet_id
}

output "expressroute_circuit_service_key" {
  description = "ExpressRoute circuit service key."
  value       = module.ergw.circuit_service_key
  sensitive   = true
}

output "gcp_pairing_key" {
  description = "GCP pairing key for the simulated on-prem connection."
  value       = var.gcp_onprem.deploy_gcp ? try(module.gcp_onprem[0].pairing_key, null) : null
  sensitive   = true
}
