# Switch — History

## Project Context
- **Project:** azure-hub-spoke — Hub-and-Spoke networking labs on Azure.
- **Key fact:** Each top-level folder is a distinct, self-contained lab scenario covering a specific connectivity/routing pattern.
- **Stack:** ExpressRoute, VPN Gateway, Azure Route Server (BGP), OPNSense NVA, multi-cloud (GCP via Megaport).
- **Created:** 2026-06-04

## Learnings
- 2026-06-04T17:29:07-05:00 — er-migration Terraform docs now include the manual Megaport key-exchange step for Azure ER service keys and GCP Partner Interconnect pairing keys because the VXC cross-connect cannot be safely automated end-to-end.
- 2026-06-04T16:25:05-05:00 — er-migration scripts create a single 50 Mbps Standard/Metered Megaport ExpressRoute circuit in Chicago and a single GCP Partner Interconnect VLAN attachment; treat this as a lab-only topology without circuit/location/provider redundancy.
- 2026-06-04T16:25:05-05:00 — er-migration `3-add-subnetprefix.sh` attempts to add `10.0.0.64/26` to `GatewaySubnet`, but `1-hub-spk.sh` assigns that same prefix to Azure Firewall; this is overlapping/risky and should be corrected before use.
- 2026-06-04T16:25:05-05:00 — er-migration validation uses gateway `adminState` toggling for cutover and references `az-hub-ergw_migrated`; prefer BGP/connection preference controls and explicit rollback validation over disabling gateways as the primary migration mechanism.
- 2026-06-04T17:42:48-05:00 — Created terraform/modules/gcp-onprem as a GCP Partner Interconnect simulator; the VLAN attachment exposes a sensitive pairing_key for the manual Megaport VXC exchange.
- 2026-06-04T17:36:55-05:00 — azure-ergw migration module uses ExpressRoute connection routing_weight as the cutover/rollback lever; adminState remains documented fallback only, and Megaport VXC provisioning stays manual.
- 2026-06-06T19:43:25-05:00 — **Failed connection root cause + remediation pattern:** `az-hub-ergw-to-az-hub-er-circuit` was created out-of-band (via script) while the circuit `serviceProviderProvisioningState` was still `NotProvisioned`; Azure returned `ServiceProviderNotProvisioned` and the connection stuck in `Failed` state permanently (Azure gateway connections do NOT self-heal from this state). Confirmed live state at 2026-06-06T19:43:25-05:00: circuit = Succeeded/Provisioned, AzurePrivatePeering = Succeeded (peerASN 65001 / azureASN 12076), connection = Failed/null. **Remediation pattern:** (1) verify circuit is Provisioned first, (2) delete the stuck connection with `az network vpn-connection delete`, (3) add `er_circuit = { private_peering = { enabled = true, create_peering = false } }` to terraform.tfvars (Megaport owns the peering, `create_peering=false` prevents collision), (4) `terraform apply` → TF recreates and tracks the connection cleanly. Terraform config in `er-migration/terraform/modules/azure-ergw/main.tf` is correct and commit-ready — no code changes needed. Full runbook in `.squad/decisions/inbox/switch-er-connection-fix.md`.
