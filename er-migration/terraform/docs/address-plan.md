# ER Migration Terraform Address Plan

Date: 2026-06-04T17:29:07-05:00
Owner: Trinity / Lead Network Architect
Scope: Analysis-only address, ASN, and migration-gateway contract for the `er-migration` Terraform rebuild.

## Corrected address plan

The rebuild keeps the original /24 hub and the original spoke CIDRs. The overlap in the archived multi-prefix step is fixed by using the only free /27 inside `10.0.0.0/24` (`10.0.0.160/27`) as the second `GatewaySubnet` prefix. No hub expansion is required, which avoids renumbering Spoke1 (`10.0.1.0/24`).

| Network | CIDR | Purpose | Notes |
| --- | --- | --- | --- |
| `az-hub-vnet` | `10.0.0.0/24` | Azure hub VNet address space | Kept from original lab; contains all hub subnets and the corrected extra GatewaySubnet prefix. |
| `az-hub-vnet/subnet1` | `10.0.0.0/27` | Hub VM subnet | Original hub VM subnet; expected VM IP remains `10.0.0.4`. |
| `az-hub-vnet/GatewaySubnet` primary prefix | `10.0.0.32/27` | Original ExpressRoute gateway subnet prefix | Required subnet name: exactly `GatewaySubnet`; /27 is Azure minimum. |
| `az-hub-vnet/AzureFirewallSubnet` | `10.0.0.64/26` | Azure Firewall subnet | Required subnet name: exactly `AzureFirewallSubnet`; this range must not be reused by GatewaySubnet. |
| `az-hub-vnet/RouteServerSubnet` | `10.0.0.128/27` | Azure Route Server subnet | Required subnet name: exactly `RouteServerSubnet`; must be /27. |
| `az-hub-vnet/GatewaySubnet` extra prefix | `10.0.0.160/27` | Second GatewaySubnet prefix for the multi-prefix teaching point | Corrected replacement for the invalid `10.0.0.64/26`; free range between Route Server and Bastion. |
| `az-hub-vnet/AzureBastionSubnet` | `10.0.0.192/26` | Azure Bastion subnet | Required subnet name: exactly `AzureBastionSubnet`; must be /26. |
| `az-spk1-vnet` | `10.0.1.0/24` | Azure spoke 1 VNet address space | Kept from original lab; no overlap with hub because hub remains /24. |
| `az-spk1-vnet/subnet1` | `10.0.1.0/27` | Spoke 1 VM subnet | Original spoke 1 VM subnet; expected VM IP remains `10.0.1.4`. |
| `az-spk2-vnet` | `10.0.2.0/24` | Azure spoke 2 VNet address space | Kept from original lab. |
| `az-spk2-vnet/subnet1` | `10.0.2.0/27` | Spoke 2 VM subnet | Original spoke 2 VM subnet; expected VM IP remains `10.0.2.4`. |
| `gcp-on-prem-vpc` | `192.168.100.0/24` | GCP simulated on-prem network | Kept from original lab; expected VM IP remains `192.168.100.2`. |

## GatewaySubnet multi-prefix bug resolution

Archived script `archive/3-add-subnetprefix.sh` adds `10.0.0.64/26` as a second `GatewaySubnet` prefix, but that exact CIDR is already the Azure Firewall subnet. The Terraform rebuild must not reproduce that overlap.

Decision: preserve the multi-prefix teaching point and set the extra `GatewaySubnet` prefix to `10.0.0.160/27`.

Justification:

- It is the only unused /27 remaining in the current hub /24.
- It does not overlap `subnet1`, `GatewaySubnet` primary, `AzureFirewallSubnet`, `RouteServerSubnet`, or `AzureBastionSubnet`.
- It avoids expanding the hub to /23. Expanding to `10.0.0.0/23` would overlap the existing Spoke1 VNet `10.0.1.0/24` and force avoidable spoke renumbering.
- The combined GatewaySubnet capacity becomes two /27 prefixes while preserving the original lab's intent.

## ASN and ExpressRoute migration scheme

| Component | ASN | Notes |
| --- | ---: | --- |
| Original Azure ExpressRoute gateway `az-hub-ergw` | `65515` | Azure-assigned/fixed gateway ASN. |
| Migrated Azure ExpressRoute gateway `az-hub-ergw-migrated` | `65515` | Same Azure gateway ASN; both gateways share AS `65515`. |
| GCP Cloud Router | `16550` | GCP-side BGP ASN from original lab. |
| ExpressRoute circuit | `12076` | Microsoft/ExpressRoute circuit-side ASN for private peering. |
| Provider router / Megaport side | `65001` | Provider/on-prem-side private ASN from original lab. |

Migration note: the lab migrates traffic from `az-hub-ergw` to `az-hub-ergw-migrated`. Prefer a controlled routing cutover rather than hard-disabling the old gateway first. Use ExpressRoute connection `routing_weight` on Azure for VNet-to-ER path preference, and use advertised-prefix selection, route filtering, or AS-path prepending on the GCP/provider side for return-path control. Keep gateway or connection `adminState` disable/enable as a documented fallback or rollback lever only. Because both Azure ER gateways use ASN `65515`, distinguish paths by connection/gateway, learned prefixes, and BGP attributes rather than by Azure ASN.

## Terraform subnet and variable contract

Recommended module inputs:

```hcl
variable "hub" {
  type = object({
    name          = string
    address_space = list(string)
    subnets = list(object({
      name             = string
      address_prefixes = list(string)
      purpose          = optional(string)
    }))
    gateway_subnet_extra_prefix = string
  })

  default = {
    name          = "az-hub-vnet"
    address_space = ["10.0.0.0/24"]
    gateway_subnet_extra_prefix = "10.0.0.160/27"
    subnets = [
      { name = "subnet1",             address_prefixes = ["10.0.0.0/27"],   purpose = "hub-vm" },
      { name = "GatewaySubnet",       address_prefixes = ["10.0.0.32/27", "10.0.0.160/27"], purpose = "expressroute-gateways" },
      { name = "AzureFirewallSubnet", address_prefixes = ["10.0.0.64/26"],  purpose = "azure-firewall" },
      { name = "RouteServerSubnet",   address_prefixes = ["10.0.0.128/27"], purpose = "azure-route-server" },
      { name = "AzureBastionSubnet",  address_prefixes = ["10.0.0.192/26"], purpose = "azure-bastion" }
    ]
  }
}

variable "spokes" {
  type = map(object({
    name          = string
    address_space = list(string)
    subnets = list(object({
      name             = string
      address_prefixes = list(string)
      vm_private_ip    = optional(string)
    }))
  }))

  default = {
    spk1 = {
      name          = "az-spk1-vnet"
      address_space = ["10.0.1.0/24"]
      subnets       = [{ name = "subnet1", address_prefixes = ["10.0.1.0/27"], vm_private_ip = "10.0.1.4" }]
    }
    spk2 = {
      name          = "az-spk2-vnet"
      address_space = ["10.0.2.0/24"]
      subnets       = [{ name = "subnet1", address_prefixes = ["10.0.2.0/27"], vm_private_ip = "10.0.2.4" }]
    }
  }
}

variable "gcp_onprem" {
  type = object({
    deploy_gcp       = bool
    network_name     = string
    network_cidr     = string
    subnet_cidr      = string
    vm_private_ip    = string
    cloud_router_asn = number
  })

  default = {
    deploy_gcp       = true
    network_name     = "gcp-on-prem-vpc"
    network_cidr     = "192.168.100.0/24"
    subnet_cidr      = "192.168.100.0/24"
    vm_private_ip    = "192.168.100.2"
    cloud_router_asn = 16550
  }
}

variable "expressroute_migration" {
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

  default = {
    circuit_asn                = 12076
    provider_router_asn        = 65001
    azure_gateway_asn          = 65515
    original_gateway_name      = "az-hub-ergw"
    migrated_gateway_name      = "az-hub-ergw-migrated"
    original_connection_weight = 0
    migrated_connection_weight = 100
    admin_state_fallback       = true
  }
}
```

Implementation notes for Tank/Switch:

- Model Azure subnet prefixes as `address_prefixes` lists, not a single `address_prefix`, so `GatewaySubnet` can carry both prefixes.
- Preserve required Azure subnet names exactly: `GatewaySubnet`, `AzureFirewallSubnet`, `RouteServerSubnet`, and `AzureBastionSubnet`.
- Add Terraform validation or a pre-plan CI check that rejects overlapping sibling subnets and overlapping VNet/VPC address spaces.
- Keep `deploy_gcp` as a feature flag so Azure-only validation can run without provisioning GCP resources.

## Python `ipaddress` overlap check result

```text
VNet/VPC CIDR check: PASS - no overlaps
Hub sibling subnet check: PASS - no overlaps
Containment check: PASS - all subnet prefixes are inside their parent networks
RESULT: CLEAN - corrected address plan is overlap-free
```

Analysis only — verify against vendor documentation before applying.
