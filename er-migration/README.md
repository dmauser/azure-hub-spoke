# ExpressRoute migration lab

This lab demonstrates an Azure hub-spoke environment connected to a GCP-simulated on-premises network through Azure ExpressRoute and Megaport. It models migration from an original ExpressRoute virtual network gateway (`az-hub-ergw`) to a migrated gateway (`az-hub-ergw-migrated`) by changing ExpressRoute connection routing preference. The lab was rebuilt from imperative Azure CLI, shell, and `gcloud` scripts, which now live in `archive/`, into Terraform under `terraform/`.

## Architecture

![er-migration topology](./diagrams/er-migration.svg)

### Address plan

| Network | CIDR | Purpose | Notes |
| --- | --- | --- | --- |
| `az-hub-vnet` | `10.0.0.0/24` | Azure hub VNet address space | Contains all hub subnets and the corrected extra `GatewaySubnet` prefix. |
| `az-hub-vnet/subnet1` | `10.0.0.0/27` | Hub VM subnet | Hub VM static IP is `10.0.0.4`. |
| `az-hub-vnet/GatewaySubnet` primary prefix | `10.0.0.32/27` | Original ExpressRoute gateway subnet prefix | Required Azure subnet name: exactly `GatewaySubnet`. |
| `az-hub-vnet/AzureFirewallSubnet` | `10.0.0.64/26` | Reserved Azure Firewall subnet | Required Azure subnet name: exactly `AzureFirewallSubnet`. |
| `az-hub-vnet/RouteServerSubnet` | `10.0.0.128/27` | Azure Route Server subnet | Required Azure subnet name: exactly `RouteServerSubnet`. |
| `az-hub-vnet/GatewaySubnet` extra prefix | `10.0.0.160/27` | Second `GatewaySubnet` prefix | Corrected replacement for the archived overlapping `10.0.0.64/26` step. |
| `az-hub-vnet/AzureBastionSubnet` | `10.0.0.192/26` | Azure Bastion subnet | Required Azure subnet name: exactly `AzureBastionSubnet`. |
| `az-spk1-vnet` | `10.0.1.0/24` | Azure spoke 1 VNet | Spoke 1 VM static IP is `10.0.1.4`. |
| `az-spk1-vnet/subnet1` | `10.0.1.0/27` | Spoke 1 VM subnet | Peered to the hub with remote gateway transit enabled. |
| `az-spk2-vnet` | `10.0.2.0/24` | Azure spoke 2 VNet | Spoke 2 VM static IP is `10.0.2.4`. |
| `az-spk2-vnet/subnet1` | `10.0.2.0/27` | Spoke 2 VM subnet | Peered to the hub with remote gateway transit enabled. |
| `gcp-on-prem-vpc` | `192.168.100.0/24` | GCP simulated on-premises VPC/subnet | GCP VM static IP is `192.168.100.2`. |

### ASN plan

| Component | ASN | Notes |
| --- | ---: | --- |
| Original Azure ExpressRoute gateway `az-hub-ergw` | `65515` | Azure gateway ASN used by this lab. |
| Migrated Azure ExpressRoute gateway `az-hub-ergw-migrated` | `65515` | Same Azure gateway ASN; distinguish paths by gateway connection and BGP attributes. |
| GCP Cloud Router | `16550` | GCP-side BGP ASN from the original lab. |
| ExpressRoute circuit | `12076` | Microsoft/ExpressRoute circuit-side ASN for private peering. |
| Provider router / Megaport side | `65001` | Provider/on-prem-side private ASN from the original lab. |

## Repository layout

```text
er-migration/
├── README.md
├── diagrams/
│   └── er-migration.svg
├── archive/
│   ├── README.md
│   ├── 1-hub-spk.sh
│   ├── 2-gcp-er.sh
│   ├── 3-add-subnetprefix.sh
│   ├── 4-validation.sh
│   ├── 5-clean-up.sh
│   └── gw-prepare.png
└── terraform/
    ├── backend.tf
    ├── locals.tf
    ├── main.tf
    ├── outputs.tf
    ├── providers.tf
    ├── terraform.tfvars.example
    ├── variables.tf
    ├── versions.tf
    ├── docs/
    │   ├── address-plan.md
    │   └── megaport-cross-connect.md
    └── modules/
        ├── azure-hub/
        ├── azure-spoke/
        ├── azure-routeserver/
        ├── azure-ergw/
        └── gcp-onprem/
```

The root Terraform configuration creates the Azure resource group and wires these modules:

- `module.hub`: `az-hub-vnet`, required hub subnets, hub NSG, hub Ubuntu VM, and optional Azure Bastion controlled by `deploy_bastion`.
- `module.spokes`: `az-spk1-vnet` and `az-spk2-vnet`, spoke subnets, NSGs, Ubuntu VMs, and hub-spoke peerings with gateway transit settings.
- `module.routeserver`: Azure Route Server `az-route-server` and public IP `az-route-server-pip`.
- `module.ergw`: ExpressRoute circuit `az-hub-er-circuit`, optional Azure private peering, both ExpressRoute gateways, and both ExpressRoute gateway connections.
- `module.gcp_onprem`: optional GCP VPC, subnet, firewall, VM, Cloud Router, and Partner Interconnect VLAN attachment.

## Prerequisites

- Azure CLI authenticated to the target subscription.
- Terraform `>= 1.5.0`.
- Optional for the GCP side: `gcloud` authenticated to a GCP project with permissions for Compute Engine, Cloud Router, and Partner Interconnect resources.
- A Megaport account with permissions to create VXCs for the manual cross-connect.
- Budget approval: ExpressRoute circuits, ExpressRoute gateways, Azure Route Server, Azure Bastion, VMs, public IPs, Megaport VXCs, and GCP resources can incur real charges.

## Deploy options: `deploy_gcp`

The consumer chooses whether to deploy only Azure or both clouds:

- **Azure-only validation**: set `gcp_onprem.deploy_gcp = false`. Terraform deploys the Azure hub, spokes, Route Server, ExpressRoute circuit, and dual ExpressRoute gateways; `gcp_pairing_key` is `null`.
- **Azure + GCP lab**: set `gcp_onprem.deploy_gcp = true` and provide `gcp_project`. Terraform also deploys the GCP simulated on-premises network and creates a Partner Interconnect VLAN attachment whose pairing key is used in Megaport.

## Quick start: fully automated Terraform apply

From `er-migration\terraform`:

```powershell
terraform init
terraform plan -var "admin_password=<strong-pwd>"
terraform apply -var "admin_password=<strong-pwd>"
```

To choose Azure-only:

```powershell
terraform plan `
  -var "admin_password=<strong-pwd>" `
  -var 'gcp_onprem={deploy_gcp=false,network_name="gcp-on-prem-vpc",network_cidr="192.168.100.0/24",subnet_cidr="192.168.100.0/24",vm_private_ip="192.168.100.2",cloud_router_asn=16550}'
```

To deploy Azure + GCP:

```powershell
terraform plan `
  -var "admin_password=<strong-pwd>" `
  -var "gcp_project=<your-gcp-project>"
```

You can also copy `terraform.tfvars.example` to `terraform.tfvars`, set `admin_password`, `gcp_project`, and `gcp_onprem.deploy_gcp`, then run `terraform plan` and `terraform apply`.

Read the key outputs after apply:

```powershell
terraform output -raw expressroute_circuit_service_key
terraform output -raw gcp_pairing_key
```

Use the ExpressRoute circuit service key for the Azure Megaport VXC. Use the GCP pairing key for the GCP Partner Interconnect VXC when `deploy_gcp = true`.

## Step-by-step: learn by doing

> `-target` is useful for learning and inspection, but prefer normal `terraform plan` and `terraform apply` for repeatable end-to-end deployments.

1. **Deploy the Azure hub, spokes, and Route Server.**  
   Why: this builds the Azure routing domain: hub VNet, spoke VNets, VM subnets, optional Bastion, peerings, and Azure Route Server. For a dependency-safe staged walkthrough, start by targeting the hub and Route Server; the spoke module enables `use_remote_gateways`, so deploy the spokes with or after the ExpressRoute gateways.

   ```powershell
   terraform apply `
     -target=module.hub `
     -target=module.routeserver `
     -var "admin_password=<strong-pwd>"
   ```

2. **Deploy the ExpressRoute circuit and dual ExpressRoute gateways.**  
   Why: the migration demo needs both `az-hub-ergw` and `az-hub-ergw-migrated` connected to the same ExpressRoute circuit.

   ```powershell
   terraform apply `
     -target=module.ergw `
     -target=module.spokes `
     -var "admin_password=<strong-pwd>"

   terraform output -raw expressroute_circuit_service_key
   ```

   The default circuit settings in `modules\azure-ergw` are provider `Megaport`, peering location `Chicago`, bandwidth `50` Mbps, SKU `Standard` / `MeteredData`. Private peering is optional and disabled by default unless `er_circuit.private_peering.enabled` is set inside the module contract.

3. **Manually create the Megaport Azure VXC and exchange the Azure service key.**  
   Why: Terraform creates the Azure circuit, but the provider cross-connect is a credentialed Megaport portal step with real billing. Follow [`terraform/docs/megaport-cross-connect.md`](./terraform/docs/megaport-cross-connect.md).

4. **Deploy the GCP simulated on-premises site and finish the GCP VXC.**  
   Why: this creates the GCP VPC `gcp-on-prem-vpc`, VM, Cloud Router, and Partner Interconnect attachment used as the on-premises side of the lab.

   ```powershell
   terraform apply `
     -target=module.gcp_onprem `
     -var "admin_password=<strong-pwd>" `
     -var "gcp_project=<your-gcp-project>"

   terraform output -raw gcp_pairing_key
   ```

   Use the pairing key in Megaport to create the GCP Partner Interconnect VXC, then wait for the Azure provider state and GCP VLAN attachment state to become provisioned/active.

5. **Verify BGP and learned routes.**  
   Why: traffic migration only makes sense after the ExpressRoute and GCP sides have established routing.

   ```powershell
   az network express-route show `
     --resource-group lab-er-migration `
     --name az-hub-er-circuit `
     --query serviceProviderProvisioningState `
     --output tsv

   az network express-route peering list `
     --resource-group lab-er-migration `
     --circuit-name az-hub-er-circuit `
     --output table

   gcloud compute routers get-status gcp-on-prem-vpc-router `
     --region us-east1 `
     --project <your-gcp-project>
   ```

   Confirm that Azure and GCP learn the expected lab prefixes: Azure `10.0.0.0/24`, spokes `10.0.1.0/24` and `10.0.2.0/24` as applicable, and GCP `192.168.100.0/24`.

6. **Run the migration demo.**  
   Why: the teaching point is a controlled cutover from the original ER gateway connection to the migrated ER gateway connection.

   The module creates two `azurerm_virtual_network_gateway_connection` resources:

   - `az-hub-ergw-to-az-hub-er-circuit`
   - `az-hub-ergw-migrated-to-az-hub-er-circuit`

   The intended cutover lever is `expressroute_migration.*_connection_weight`. Deploy with the original connection preferred, then raise `migrated_connection_weight` above `original_connection_weight` and apply:

   ```hcl
   expressroute_migration = {
     circuit_asn                = 12076
     provider_router_asn        = 65001
     azure_gateway_asn          = 65515
     original_gateway_name      = "az-hub-ergw"
     migrated_gateway_name      = "az-hub-ergw-migrated"
     original_connection_weight = 0
     migrated_connection_weight = 100
     admin_state_fallback       = true
   }
   ```

   ```powershell
   terraform apply -var "admin_password=<strong-pwd>"
   ```

   If the route-weight change does not produce the required operational result, use gateway or connection `adminState` disable/enable only as the documented manual fallback. Roll back by lowering `migrated_connection_weight` and raising `original_connection_weight`, or by reversing the manual `adminState` change if you used the fallback.

7. **Validate connectivity.**  
   Why: confirm data-plane behavior, not just control-plane status. Test SSH/Bastion access to Azure VMs, ping or TCP connectivity between Azure and GCP where allowed by NSGs/firewalls, effective routes on Azure NICs, ExpressRoute learned routes, and GCP Cloud Router status.

8. **Clean up.**  
   Why: the lab uses billable cloud and Megaport resources.

   ```powershell
   terraform destroy -var "admin_password=<strong-pwd>"
   ```

   Also remove any Megaport VXCs created manually; Terraform cannot destroy portal-created VXCs.

## Validation

Run formatting and Terraform validation from `er-migration\terraform`:

```powershell
terraform fmt -recursive -check
terraform validate
```

See [`terraform/docs/validation-report.md`](./terraform/docs/validation-report.md) for the captured validation evidence (commands run, results, and any fixes applied) for the Terraform rebuild.

## Security and cost notes

- Do not commit plaintext passwords or local `terraform.tfvars` files. `admin_password` is a required sensitive variable and must be supplied through a secure local mechanism such as `terraform.tfvars`, `TF_VAR_admin_password`, or an interactive variable prompt.
- The default VM authentication uses `admin_username` and `admin_password` with password authentication enabled for the lab VMs.
- This lab can create real Azure, GCP, and Megaport charges. Destroy Terraform-managed resources and manually delete Megaport VXCs when finished.

## Credits and archive

The original imperative lab scripts are preserved in [`archive/`](./archive/) for historical reference. The Terraform rebuild is the authoritative implementation for the current lab, with address and cross-connect design notes in [`terraform/docs/address-plan.md`](./terraform/docs/address-plan.md) and [`terraform/docs/megaport-cross-connect.md`](./terraform/docs/megaport-cross-connect.md).
