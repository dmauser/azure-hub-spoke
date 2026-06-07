variable "resource_group_name" {
  description = "Name of the resource group that will contain the ExpressRoute circuit, gateway, public IP, and connection."
  type        = string
}

variable "location" {
  description = "Azure region for the ExpressRoute circuit and virtual network gateway."
  type        = string
}

variable "tags" {
  description = "Tags to apply to all Azure resources created by this module."
  type        = map(string)
  default     = {}
}

variable "gateway_subnet_id" {
  description = "Resource ID of the hub GatewaySubnet used by the ExpressRoute gateway."
  type        = string
}

variable "er_gateway" {
  description = "ExpressRoute virtual network gateway settings. A single gateway is created; SKU/AZ migration is performed with Azure managed gateway migration."
  type = object({
    name           = string
    asn            = number
    sku            = string
    routing_weight = number
  })

  validation {
    condition     = var.er_gateway.asn == 65515
    error_message = "Azure ExpressRoute virtual network gateways in this lab must use Azure ASN 65515."
  }

  validation {
    condition     = var.er_gateway.routing_weight >= 0
    error_message = "ExpressRoute connection routing weight must be non-negative."
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
      # enabled        : master switch. When true, the gateway-to-circuit connection is created.
      # create_peering : whether Terraform creates the AzurePrivatePeering on the circuit.
      #   Set false when a managed/Layer-2 provider (e.g. Megaport) auto-creates the peering,
      #   so Terraform only manages the connection and does not collide with the provider peering.
      enabled                       = optional(bool, false)
      create_peering                = optional(bool, true)
      peer_asn                      = optional(number, 65001)
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
    # Peer prefixes/VLAN are only required when Terraform itself creates the peering.
    # With a managed provider peering (create_peering = false) the connection needs none of these.
    condition = !(var.er_circuit.private_peering.enabled && var.er_circuit.private_peering.create_peering) || alltrue([
      var.er_circuit.private_peering.vlan_id != null,
      var.er_circuit.private_peering.primary_peer_address_prefix != null,
      var.er_circuit.private_peering.secondary_peer_address_prefix != null
    ])
    error_message = "When er_circuit.private_peering.enabled and create_peering are both true, vlan_id and both /30 peer address prefixes are required."
  }
}
