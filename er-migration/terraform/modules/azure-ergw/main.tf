terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

locals {
  gateways = {
    original = {
      name           = var.expressroute_migration.original_gateway_name
      routing_weight = var.expressroute_migration.original_connection_weight
    }
    migrated = {
      name           = var.expressroute_migration.migrated_gateway_name
      routing_weight = var.expressroute_migration.migrated_connection_weight
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
# provider/on-prem router ASN (for this lab, provider_router_asn = 65001), while Azure reports
# its circuit/Microsoft-edge ASN separately (expected circuit_asn = 12076).
resource "azurerm_express_route_circuit_peering" "private" {
  count = var.er_circuit.private_peering.enabled ? 1 : 0

  peering_type                  = "AzurePrivatePeering"
  express_route_circuit_name    = azurerm_express_route_circuit.this.name
  resource_group_name           = var.resource_group_name
  peer_asn                      = var.expressroute_migration.provider_router_asn
  primary_peer_address_prefix   = var.er_circuit.private_peering.primary_peer_address_prefix
  secondary_peer_address_prefix = var.er_circuit.private_peering.secondary_peer_address_prefix
  vlan_id                       = var.er_circuit.private_peering.vlan_id
  ipv4_enabled                  = true
}

resource "azurerm_public_ip" "gateway" {
  for_each = local.gateways

  name                = "${each.value.name}-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Dynamic"

  tags = var.tags
}

resource "azurerm_virtual_network_gateway" "gateway" {
  for_each = local.gateways

  name                = each.value.name
  resource_group_name = var.resource_group_name
  location            = var.location
  type                = "ExpressRoute"
  sku                 = "Standard"
  active_active       = false
  bgp_enabled         = true

  # Standard is intentional for this 50 Mbps lab: Microsoft documents Standard/ErGw1Az
  # at the same 1 Gbps/4-circuit tier, while Standard avoids AZ-SKU regional constraints.
  # Both gateways use AS 65515, so migration paths are distinguished by gateway connection
  # and routing_weight rather than by Azure ASN.
  bgp_settings {
    asn = var.expressroute_migration.azure_gateway_asn
  }

  ip_configuration {
    name                          = "${each.key}-ergw-ipconfig"
    public_ip_address_id          = azurerm_public_ip.gateway[each.key].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = var.gateway_subnet_id
  }

  tags = var.tags
}

# Migration runbook:
# 1. Deploy with original_connection_weight high and migrated_connection_weight low.
# 2. Cut over by raising migrated_connection_weight above original_connection_weight.
# 3. Only if var.expressroute_migration.admin_state_fallback is true, operators may use
#    adminState disable/enable on the original connection/gateway as a manual fallback;
#    Terraform keeps routing_weight as the primary cutover lever.
# 4. Roll back by reverting the two routing weights.
# The circuit must first be provisioned manually in Megaport with the Azure service key as
# described in docs/megaport-cross-connect.md; connections remain down until provider state
# and private peering are provisioned.
resource "azurerm_virtual_network_gateway_connection" "circuit" {
  for_each = local.gateways

  name                = "${each.value.name}-to-${var.er_circuit.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  type                = "ExpressRoute"

  virtual_network_gateway_id = azurerm_virtual_network_gateway.gateway[each.key].id
  express_route_circuit_id   = azurerm_express_route_circuit.this.id
  routing_weight             = each.value.routing_weight

  tags = var.tags

  depends_on = [azurerm_express_route_circuit_peering.private]
}
