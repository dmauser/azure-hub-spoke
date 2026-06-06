# Terraform Validation Report

Date: 2026-06-04T17:48:45-05:00
Scope: Static validation only; no backend init, plan against credentials, or apply was run.

## Commands run

| Command | Result | Notes |
| --- | --- | --- |
| `terraform version` | PASS | Terraform v1.15.4 on windows_amd64. |
| `terraform fmt -recursive -check` | PASS | Initial check passed; no formatting changes required. Re-ran after fixes and it still passed. |
| `terraform init -backend=false` | PASS | Providers initialized without backend/state access: azurerm v4.76.0, google v7.35.0, random v3.9.0. |
| `terraform validate` | FAIL then PASS | Initial validation failed on a bad root output reference. After fixes, `Success! The configuration is valid.` |
| Python `ipaddress` CIDR overlap check | PASS | VNet/VPC CIDR check, hub sibling subnet check, and hub containment check all passed. |

## Fixes applied

- Fixed root output `expressroute_circuit_service_key` to reference the actual ER module output `module.ergw.circuit_service_key`.
- Updated `azurerm_virtual_network_gateway` from deprecated `enable_bgp` to `bgp_enabled` for AzureRM v4 compatibility and to avoid the v5 removal warning.
- Marked root output `gcp_pairing_key` as `sensitive = true` because it forwards the sensitive GCP Partner Interconnect pairing key.

## Static design checks

- No CIDR overlaps found. Terraform defaults match `docs/address-plan.md`: hub `10.0.0.0/24`, spokes `10.0.1.0/24` and `10.0.2.0/24`, and GCP/on-prem `192.168.100.0/24`.
- Hub sibling subnets are non-overlapping and contained in the hub VNet. `GatewaySubnet` has two prefixes: `10.0.0.32/27` and `10.0.0.160/27`.
- Required Azure subnet names are exact: `GatewaySubnet`, `AzureFirewallSubnet`, `RouteServerSubnet`, and `AzureBastionSubnet`.
- `deploy_gcp=false` path is statically safe: root module `gcp_onprem` uses `count = var.gcp_onprem.deploy_gcp ? 1 : 0`, and root output access is guarded with `try(module.gcp_onprem[0].pairing_key, null)`.
- `admin_password` has no default, is marked sensitive in root and Azure modules, and no plaintext passwords or real secrets were found. `terraform.tfvars.example` uses placeholders only.
- ER migration uses `routing_weight` on `azurerm_virtual_network_gateway_connection` as the primary cutover lever. The ER circuit service key is output as sensitive.

## Manual deploy note

When ready to deploy manually, run from `er-migration\terraform`:

```powershell
terraform init
terraform plan -var 'admin_password=<strong-password>' -var 'gcp_onprem={deploy_gcp=false,network_name="gcp-on-prem-vpc",network_cidr="192.168.100.0/24",subnet_cidr="192.168.100.0/24",vm_private_ip="192.168.100.2",cloud_router_asn=16550}'
terraform apply -var 'admin_password=<strong-password>' -var 'gcp_onprem={deploy_gcp=false,network_name="gcp-on-prem-vpc",network_cidr="192.168.100.0/24",subnet_cidr="192.168.100.0/24",vm_private_ip="192.168.100.2",cloud_router_asn=16550}'
```

Set `deploy_gcp=true` and provide `gcp_project`, `gcp_region`, and `gcp_zone` when intentionally deploying the GCP simulated on-prem side.

Analysis only — verify against vendor documentation before applying.
