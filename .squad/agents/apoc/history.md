# Apoc — History

## Project Context
- **Project:** azure-hub-spoke — Hub-and-Spoke networking labs on Azure.
- **Key fact:** Each top-level folder is a distinct, self-contained lab scenario; many ship a dedicated validation script.
- **Stack:** Azure CLI, ExpressRoute, VPN Gateway, Azure Route Server, OPNSense NVA, GCP/Megaport.
- **Created:** 2026-06-04

## Learnings

- 2026-06-04: Static Terraform validation passed for er-migration after fixing ER service-key output reference, AzureRM BGP attribute, and sensitive GCP pairing-key output.
