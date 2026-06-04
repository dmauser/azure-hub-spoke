# Squad Decisions

## Active Decisions

### ER migration connectivity/routing posture

- Date: 2026-06-04T16:25:05-05:00
- Lab: er-migration
- Owner: Switch (Hybrid Connectivity & Routing)
- Status: Proposed

Treat the current er-migration topology as a functional lab, not a production migration pattern. Before presenting it as a safe migration cutover design, fix the GatewaySubnet overlap in `3-add-subnetprefix.sh`, replace gateway `adminState` cutover with route-preference based cutover where possible, and document single-circuit/single-location ExpressRoute and single GCP VLAN attachment limitations.

Key routing findings:

1. `1-hub-spk.sh` creates one 50 Mbps Standard/Metered Megaport ExpressRoute circuit in Chicago. This lacks circuit, provider, and peering-location redundancy.
2. `2-gcp-er.sh` creates one regional Cloud Router and one Partner Interconnect VLAN attachment in `us-east1`; production-like GCP redundancy needs additional attachments/edge availability domains according to Google Partner Interconnect guidance.
3. `3-add-subnetprefix.sh` adds `10.0.0.64/26` to `GatewaySubnet`, but `1-hub-spk.sh` uses `10.0.0.64/26` for Azure Firewall. This appears invalid because VNet subnets cannot overlap.
4. Azure Route Server is deployed by the base template, but the lab scripts do not explicitly configure NVA peers or enable route exchange/branch-to-branch; migration validation should prove exactly which prefixes are learned by ERGW, Route Server, spokes, and GCP.
5. `4-validation.sh` toggles `adminState` and uses `az network vnet-vpn-gateway update` for `az-hub-ergw_migrated`; validate object type/CLI command before use. Prefer controlled BGP policy, connection routing weight, or AS-path/local-preference changes for cutover tests.

References:

- Azure ExpressRoute circuits/private peering use redundant BGP sessions per peering and require both sessions for SLA: https://learn.microsoft.com/en-us/azure/expressroute/expressroute-routing
- ExpressRoute circuit bandwidth/SKU/peering location basics: https://learn.microsoft.com/en-us/azure/expressroute/expressroute-circuit-peerings
- ExpressRoute FastPath requirements and limitations: https://learn.microsoft.com/en-us/azure/expressroute/about-fastpath
- ExpressRoute Global Reach links ExpressRoute circuits for on-premises-to-on-premises connectivity: https://learn.microsoft.com/en-us/azure/expressroute/expressroute-global-reach
- Azure Route Server route exchange with ExpressRoute/VPN gateways: https://learn.microsoft.com/en-us/azure/route-server/expressroute-vpn-support
- Azure multiple subnet prefixes limitations: https://learn.microsoft.com/en-us/azure/virtual-network/how-to-multiple-prefixes-subnet
- Google Partner Interconnect redundancy/SLA and VLAN attachment behavior: https://docs.cloud.google.com/network-connectivity/docs/interconnect/concepts/partner-overview?hl=en

### ER migration script hygiene and hardening

- Date: 2026-06-04T16:25:05-05:00
- Lab: er-migration
- Owner: Tank (Infra / IaC Engineer)
- Status: Proposed

Treat the current shell scripts as prototype lab automation and harden them before reuse: remove plaintext credentials, externalize environment-specific values into a shared vars file, pin all remote templates and image inputs, add Bash strict mode and validation, make deployments rerun-safe, and split validation/scratch commands from deploy and cleanup paths.

Rationale:

The reviewed scripts contain a plaintext VM password, a remote ARM template pinned to `main`, hardcoded GCP project and location values, asynchronous deployment sequencing with ad hoc polling, no shebang or strict error mode, and validation commands mixed with experimental snippets. These create security, reproducibility, and rerun-safety risks for a self-contained lab.

Concrete follow-up:

Create `lab.env.example` / `lab.env` pattern, replace secrets with Key Vault or secure prompts, pin `azuredeployv5.json` to an immutable release/commit or vendor it locally, pin GCP image selection, add `validate/what-if` modes, refactor wait/delete helpers, and clean `4-validation.sh` into documented validation-only commands.

### 2026-06-04T17:29:07-05:00: Trinity Address Plan Decision

- **By:** Trinity (Lead Network Architect)
- **Status:** Approved

Preserve the ExpressRoute lab's GatewaySubnet multi-prefix teaching point, but replace the invalid extra prefix `10.0.0.64/26` with `10.0.0.160/27`.

**Why:**
- `10.0.0.64/26` is already assigned to `AzureFirewallSubnet`, creating a hard overlap.
- `10.0.0.160/27` is the only free /27 inside the current hub `10.0.0.0/24`.
- Keeping the hub at `10.0.0.0/24` avoids expanding to `10.0.0.0/23`, which would collide with Spoke1 `10.0.1.0/24`.
- Required Azure subnet names remain exact: `GatewaySubnet`, `AzureFirewallSubnet`, `RouteServerSubnet`, `AzureBastionSubnet`.

**Contract impact:** Terraform modules should expose hub subnet definitions as name plus `address_prefixes` list. `GatewaySubnet` must include `10.0.0.32/27` and `10.0.0.160/27`. Expose `deploy_gcp`, spoke definitions, ASN values, original/migrated gateway names, and ExpressRoute connection routing weights.

**Validation:** Python `ipaddress` check result: `RESULT: CLEAN - corrected address plan is overlap-free`.

### 2026-06-04T17:36:55-05:00: Switch ER Gateway Migration Design

- **By:** Switch (Hybrid Connectivity & Routing)
- **Status:** Approved

Model the original and migrated ExpressRoute virtual network gateways with identical Azure gateway ASN `65515` and use `azurerm_virtual_network_gateway_connection.routing_weight` as the primary cutover and rollback lever. Keep `adminState` disable/enable as an operator-only fallback documented by `expressroute_migration.admin_state_fallback`.

**Key decisions:**
1. Use `routing_weight` as primary cutover/rollback mechanism (Terraform exposes this in azurerm v4).
2. Keep `adminState` disable/enable as operator-only fallback because Terraform does not expose gateway admin-state toggle.
3. Use ExpressRoute gateway SKU `Standard` for this lab (Standard and ErGw1Az map to the same 1 Gbps / 4 circuit tier; Standard avoids zone SKU regional constraints).
4. Include optional `azurerm_express_route_circuit_peering` for `AzurePrivatePeering` with `peer_asn = provider_router_asn`; Azure circuit ASN `12076` documented as `expressroute_migration.circuit_asn`.

**References:**
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/express_route_circuit
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/express_route_circuit_peering
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_gateway
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_gateway_connection
- https://learn.microsoft.com/azure/expressroute/expressroute-about-virtual-network-gateways
- https://learn.microsoft.com/azure/expressroute/expressroute-howto-routing-portal-resource-manager

### 2026-06-04T17:48:45-05:00: Apoc Terraform Validation Fixes

- **By:** Apoc (Validation & Testing)
- **Status:** Applied

Applied objective static-validation fixes after `terraform validate`:

1. Root `expressroute_circuit_service_key` now references `module.ergw.circuit_service_key`, matching the ER module output.
2. `azurerm_virtual_network_gateway.gateway` now uses `bgp_enabled = true` instead of deprecated `enable_bgp = true`.
3. Root `gcp_pairing_key` output is marked sensitive to forward the sensitive GCP module pairing key.

Validation now passes with `terraform validate`; no backend, plan, or apply was run.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
