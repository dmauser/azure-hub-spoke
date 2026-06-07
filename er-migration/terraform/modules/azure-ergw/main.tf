terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

resource "azurerm_express_route_circuit" "this" {
  name                  = var.er_circuit.name
  resource_group_name   = var.resource_group_name
  location              = var.location
  service_provider_name = var.er_circuit.provider_name
  peering_location      = var.er_circuit.peering_location
  bandwidth_in_mbps     = var.er_circuit.bandwidth_in_mbps

  sku {
    tier   = var.er_circuit.sku_tier
    family = var.er_circuit.sku_family
  }

  tags = var.tags
}

# Private peering is optional because docs/megaport-cross-connect.md keeps the Megaport VXC
# and service-key exchange manual. When enabled for a layer-2 provider path, peer_asn is the
# provider/on-prem router ASN, while Azure reports its circuit/Microsoft-edge ASN separately.
resource "azurerm_express_route_circuit_peering" "private" {
  count = var.er_circuit.private_peering.enabled && var.er_circuit.private_peering.create_peering ? 1 : 0

  peering_type                  = "AzurePrivatePeering"
  express_route_circuit_name    = azurerm_express_route_circuit.this.name
  resource_group_name           = var.resource_group_name
  peer_asn                      = var.er_circuit.private_peering.peer_asn
  primary_peer_address_prefix   = var.er_circuit.private_peering.primary_peer_address_prefix
  secondary_peer_address_prefix = var.er_circuit.private_peering.secondary_peer_address_prefix
  vlan_id                       = var.er_circuit.private_peering.vlan_id
  ipv4_enabled                  = true
}

# Single ExpressRoute virtual network gateway. The lab uses Azure managed gateway migration
# (portal/PowerShell) to move this gateway to a higher or AZ-enabled SKU; that managed flow
# temporarily creates a second gateway in the same GatewaySubnet (sized /26 for this reason)
# and removes the original after cutover. See:
# https://learn.microsoft.com/azure/expressroute/gateway-migration
#
# ExpressRoute gateways manage their public IP internally. The azurerm provider rejects
# public_ip_address_id and bgp_settings on an ExpressRoute-type gateway (Azure uses the
# fixed ASN 65515 for ExpressRoute), so ip_configuration only carries the GatewaySubnet.
resource "azurerm_virtual_network_gateway" "gateway" {
  name                = var.er_gateway.name
  resource_group_name = var.resource_group_name
  location            = var.location
  type                = "ExpressRoute"
  sku                 = var.er_gateway.sku

  ip_configuration {
    name                          = "ergw-ipconfig"
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = var.gateway_subnet_id
  }

  tags = var.tags
}

# The circuit must first be provisioned in Megaport with the Azure service key (see
# docs/megaport-cross-connect.md). Azure rejects the gateway-to-circuit connection with
# ServiceProviderNotProvisioned until the cross-connection is provisioned, so the connection
# is gated on private_peering.enabled: set it to true (after the Megaport VXC + private
# peering are configured) and re-apply to establish the ExpressRoute connection.
resource "azurerm_virtual_network_gateway_connection" "circuit" {
  count = var.er_circuit.private_peering.enabled ? 1 : 0

  name                = "${var.er_gateway.name}-to-${var.er_circuit.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  type                = "ExpressRoute"

  virtual_network_gateway_id = azurerm_virtual_network_gateway.gateway.id
  express_route_circuit_id   = azurerm_express_route_circuit.this.id
  routing_weight             = var.er_gateway.routing_weight

  tags = var.tags

  depends_on = [azurerm_express_route_circuit_peering.private]
}
