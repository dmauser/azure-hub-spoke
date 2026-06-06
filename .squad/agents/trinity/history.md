# Trinity — History

## Project Context
- **Project:** azure-hub-spoke — Labs and articles for Hub-and-Spoke network architecture on Azure.
- **Key fact:** Each top-level folder is a distinct, self-contained lab scenario (e.g., er-hub-transit, er-migration, hub-dmz-fw).
- **Stack:** Azure CLI scripts (`.azcli`, `.sh`), ExpressRoute, VPN Gateway, Azure Route Server (BGP), OPNSense NVA, multi-cloud (GCP via Megaport).
- **Created:** 2026-06-04

## Learnings
- 2026-06-04T17:29:07-05:00 — ER migration Terraform address plan keeps hub `10.0.0.0/24`, spokes `10.0.1.0/24` and `10.0.2.0/24`, and GCP `192.168.100.0/24`; fixes the archived GatewaySubnet overlap by using extra prefix `10.0.0.160/27` instead of `10.0.0.64/26`.
- 2026-06-04T17:29:07-05:00 — ER migration uses original gateway `az-hub-ergw` and migrated gateway `az-hub-ergw-migrated`; both share Azure ER gateway ASN `65515`, with routing-weight/prefix/BGP controls preferred for cutover and adminState toggle only as fallback.
## Learnings
