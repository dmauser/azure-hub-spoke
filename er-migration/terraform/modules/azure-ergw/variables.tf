variable "resource_group_name" {
  description = "Name of the resource group that will contain the ExpressRoute circuit, gateways, public IPs, and connections."
  type        = string
}

variable "location" {
  description = "Azure region for the ExpressRoute circuit and virtual network gateways."
  type        = string
}

variable "tags" {
  description = "Tags to apply to all Azure resources created by this module."
  type        = map(string)
  default     = {}
}

variable "gateway_subnet_id" {
  description = "Resource ID of the hub GatewaySubnet used by both modeled ExpressRoute gateways."
  type        = string
}

variable "expressroute_migration" {
  description = "ExpressRoute migration ASN and routing-weight cutover settings."
  type = object({
    circuit_asn                = number
    provider_router_asn        = number
    azure_gateway_asn          = number
    original_gateway_name      = string
    migrated_gateway_name      = string
    original_connection_weight = number
    migrated_connection_weight = number
    admin_state_fallback       = bool
  })

  validation {
    condition     = var.expressroute_migration.azure_gateway_asn == 65515
    error_message = "Azure ExpressRoute virtual network gateways in this lab must use Azure ASN 65515."
  }

  validation {
    condition = alltrue([
      var.expressroute_migration.original_connection_weight >= 0,
      var.expressroute_migration.migrated_connection_weight >= 0
    ])
    error_message = "ExpressRoute connection routing weights must be non-negative."
  }
}

variable "er_circuit" {
  description = "ExpressRoute circuit settings plus optional Azure private peering configuration."
  type = object({
    name              = optional(string, "az-hub-er-circuit")
    provider_name     = optional(string, "Megaport")
    peering_location  = optional(string, "Chicago")
    bandwidth_in_mbps = optional(number, 50)
    sku_tier          = optional(string, "Standard")
    sku_family        = optional(string, "MeteredData")
    private_peering = optional(object({
      enabled                       = optional(bool, false)
      vlan_id                       = optional(number)
      primary_peer_address_prefix   = optional(string)
      secondary_peer_address_prefix = optional(string)
    }), {})
  })
  default = {}

  validation {
    condition     = contains(["Basic", "Local", "Standard", "Premium"], var.er_circuit.sku_tier)
    error_message = "er_circuit.sku_tier must be Basic, Local, Standard, or Premium."
  }

  validation {
    condition     = contains(["MeteredData", "UnlimitedData"], var.er_circuit.sku_family)
    error_message = "er_circuit.sku_family must be MeteredData or UnlimitedData."
  }

  validation {
    condition = !var.er_circuit.private_peering.enabled || alltrue([
      var.er_circuit.private_peering.vlan_id != null,
      var.er_circuit.private_peering.primary_peer_address_prefix != null,
      var.er_circuit.private_peering.secondary_peer_address_prefix != null
    ])
    error_message = "When er_circuit.private_peering.enabled is true, vlan_id and both /30 peer address prefixes are required."
  }
}

