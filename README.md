# Azure Hub and Spoke Labs

Labs and articles related to Hub and Spoke network architecture on Azure. Each lab focuses on a specific connectivity or routing scenario using ExpressRoute, VPN Gateway, Azure Route Server, and NVAs such as OPNSense.

## Labs

| Lab | Description |
|-----|-------------|
| [ExpressRoute Hub Transit](#1-expressroute-hub-transit) | Route traffic between two hubs via ExpressRoute circuits |
| [ExpressRoute Migration](#2-expressroute-migration) | Migrate hub and spoke workloads to Azure via ExpressRoute from GCP on-premises |
| [Hub with DMZ Firewall (OPNSense)](#3-hub-with-dmz-firewall-opnsense) | Hub and spoke with a dedicated DMZ VNET using OPNSense NVA as firewall |
| [Hub ER+VPN Transit with OPNSense](#4-hub-ervpn-transit-with-opnsense) | Hub transit using both ExpressRoute and VPN Gateway with OPNSense on-prem emulation |
| [Hub and Spoke with ExpressRoute Gateway Scaling](#5-hub-and-spoke-with-expressroute-gateway-scaling) | Test ExpressRoute gateway scaling in a hub and spoke topology |
| [Hub and Spoke with On-Premises via ExpressRoute (Azure)](#6-hub-and-spoke-with-on-premises-via-expressroute-azure) | Hub and spoke connected to an Azure-emulated on-premises via ExpressRoute |
| [Hub and Spoke with On-Premises via ExpressRoute (GCP)](#7-hub-and-spoke-with-on-premises-via-expressroute-gcp) | Hub and spoke connected to a GCP-based on-premises via ExpressRoute |
| [ExpressRoute MSEE Hairpin](#8-expressroute-msee-hairpin) | Intra-region and inter-region traffic hairpinning through MSEE on ExpressRoute |
| [Multi-Region ExpressRoute with Azure Route Server](#9-multi-region-expressroute-with-azure-route-server) | Multi-region hub and spoke with ExpressRoute and Azure Route Server |
| [SD-WAN with Traffic Inspection](#10-sd-wan-with-traffic-inspection) | Hub and spoke with OPNSense as SD-WAN NVA and next-hop firewall load balancer |
| [Single Region VPN + ExpressRoute Coexistence](#11-single-region-vpn--expressroute-coexistence) | Hub and spoke with coexisting VPN Gateway and ExpressRoute Gateway in a single region |
| [Vendor VNET with Azure Route Server](#12-vendor-vnet-with-azure-route-server) | Third-party SD-WAN vendor VNET integrated with Azure Route Server |
| [Third-Party VNET Integration with ExpressRoute](#13-third-party-vnet-integration-with-expressroute) | Vendor VNET integration scenarios with ExpressRoute using static or BGP routing |
| [VNET with Azure Route Server, ExpressRoute, and OPNSense](#14-vnet-with-azure-route-server-expressroute-and-opnsense) | Branch VNET using OPNSense NVA connected to hub via Azure Route Server and ExpressRoute |
| [IPSec VPN over ExpressRoute (Hub and Spoke)](#15-ipsec-vpn-over-expressroute-hub-and-spoke) | IPSec tunnel over ExpressRoute private peering with Azure Route Server hub routing preference |

---

## 1. ExpressRoute Hub Transit

**Folder:** [er-hub-transit](./er-hub-transit/)

Deploys two hub and spoke environments (Hub1 and Hub2) and establishes ExpressRoute-based transit between them. Creates ExpressRoute circuits via a provider (e.g., Megaport) and connects them to each hub. Useful for validating inter-hub connectivity via ExpressRoute transit.

**Key scripts:**
- [deploy.azcli](./er-hub-transit/deploy.azcli) – Deploys both hubs and creates/connects ExpressRoute circuits

---

## 2. ExpressRoute Migration

**Folder:** [er-migration](./er-migration/)

Simulates a migration scenario where an on-premises environment (emulated with GCP) is connected to Azure via ExpressRoute. Includes hub and spoke topology with Azure Route Server, GCP partner interconnect setup via Megaport, and subnet prefix management tasks.

**Key scripts:**
- [1-hub-spk.sh](./er-migration/1-hub-spk.sh) – Deploys Azure hub and spoke environment
- [2-gcp-er.sh](./er-migration/2-gcp-er.sh) – Sets up GCP VPC and partner interconnect
- [3-add-subnetprefix.sh](./er-migration/3-add-subnetprefix.sh) – Adds subnet prefixes post-migration
- [4-validation.sh](./er-migration/4-validation.sh) – Validates connectivity
- [5-clean-up.sh](./er-migration/5-clean-up.sh) – Cleans up lab resources

---

## 3. Hub with DMZ Firewall (OPNSense)

**Folder:** [hub-dmz-fw](./hub-dmz-fw/)

Deploys a hub and spoke topology with a dedicated DMZ VNET acting as a security perimeter. OPNSense is deployed as a firewall NVA in the DMZ VNET to inspect and control traffic between spokes and on-premises. Includes Azure Route Server and on-premises connectivity via ExpressRoute and GCP.

**Key scripts:**
- [1-hub-opnfw.azcli](./hub-dmz-fw/1-hub-opnfw.azcli) – Deploys hub, spokes, and OPNSense NVA
- [2-dmz-vnet.azcli](./hub-dmz-fw/2-dmz-vnet.azcli) – Creates DMZ VNET and additional OPNSense instance
- [3-onprem-gcp-er.azcli](./hub-dmz-fw/3-onprem-gcp-er.azcli) – Provisions GCP-based on-premises and ExpressRoute
- [4-config-dmzfw.azcli](./hub-dmz-fw/4-config-dmzfw.azcli) – Configures DMZ firewall routing and policies

---

## 4. Hub ER+VPN Transit with OPNSense

**Folder:** [hub-ervpn-transit-opn](./hub-ervpn-transit-opn/)

Deploys a hub and spoke environment with both an ExpressRoute gateway and a VPN gateway enabled for transit. OPNSense is used to emulate on-premises equipment. Azure Route Server with Branch-to-Branch is enabled to support routing between VPN and ER connections.

**Key scripts:**
- [deploy.azcli](./hub-ervpn-transit-opn/deploy.azcli) – Deploys hub, spokes, OPNSense, and Azure Route Server
- [connect-er.azcli](./hub-ervpn-transit-opn/connect-er.azcli) – Connects ExpressRoute circuit to the gateway
- [validation.azcli](./hub-ervpn-transit-opn/validation.azcli) – Validates routing and connectivity
- [onprem-gcp.sh](./hub-ervpn-transit-opn/onprem-gcp.sh) – Sets up GCP-side on-premises via partner interconnect

---

## 5. Hub and Spoke with ExpressRoute Gateway Scaling

**Folder:** [hubspk-ergwscale](./hubspk-ergwscale/)

Explores ExpressRoute gateway scaling configurations in a hub and spoke topology. Provisions an ExpressRoute circuit via Megaport (Chicago) and evaluates the impact of gateway SKU and scaling settings on throughput and routing.

**Key scripts:**
- [1-hub-spk-er-scale.azcli](./hubspk-ergwscale/1-hub-spk-er-scale.azcli) – Deploys hub, spokes, and ExpressRoute circuit
- [2-gcp-er.azcli](./hubspk-ergwscale/2-gcp-er.azcli) – Creates GCP partner interconnect for on-premises emulation

---

## 6. Hub and Spoke with On-Premises via ExpressRoute (Azure)

**Folder:** [hubspk-onprem-er-azure](./hubspk-onprem-er-azure/)

Deploys a hub and spoke topology in Azure and establishes ExpressRoute connectivity to an on-premises environment emulated inside Azure using a separate VNET and ExpressRoute gateway. Includes an optional Azure Route Server + OPNSense branch scenario.

**Key scripts:**
- [1-hub-spk.azcli](./hubspk-onprem-er-azure/1-hub-spk.azcli) – Deploys Azure hub and spokes
- [2-branch.azcli](./hubspk-onprem-er-azure/2-branch.azcli) – Deploys on-premises branch environment
- [3-er-conn.azcli](./hubspk-onprem-er-azure/3-er-conn.azcli) – Creates and connects ExpressRoute circuits

---

## 7. Hub and Spoke with On-Premises via ExpressRoute (GCP)

**Folder:** [hubspk-onprem-er-gcp](./hubspk-onprem-er-gcp/)

Connects an Azure hub and spoke environment to an on-premises network emulated in GCP via ExpressRoute (Equinix or Megaport). Demonstrates cross-cloud connectivity patterns through ExpressRoute partner interconnects.

**Key scripts:**
- [1-hub-spk.azcli](./hubspk-onprem-er-gcp/1-hub-spk.azcli) – Deploys Azure hub and spoke
- [1-hub-spk-equinix.azcli](./hubspk-onprem-er-gcp/1-hub-spk-equinix.azcli) – Variant using Equinix as provider
- [2-gcp-er.azcli](./hubspk-onprem-er-gcp/2-gcp-er.azcli) – Sets up GCP VPC and partner interconnect
- [3-validation.azcli](./hubspk-onprem-er-gcp/3-validation.azcli) – Validates end-to-end connectivity

---

## 8. ExpressRoute MSEE Hairpin

**Folder:** [msee-hairpin](./msee-hairpin/)

Builds a scenario to test MSEE (Microsoft Enterprise Edge) hairpin behavior over ExpressRoute, where traffic between two virtual networks — in the same region (intra-region) or across regions (inter-region) — is routed through the ExpressRoute circuit.

**Key scripts:**
- [1-az-deploy.azcli](./msee-hairpin/1-az-deploy.azcli) – Deploys the Azure environment
- [2-gcp-deploy.azcli](./msee-hairpin/2-gcp-deploy.azcli) – Deploys GCP on-premises side
- [3-validation.azcli](./msee-hairpin/3-validation.azcli) – Validates hairpin routing behavior

---

## 9. Multi-Region ExpressRoute with Azure Route Server

**Folder:** [multi-region-er-ars](./multi-region-er-ars/)

Deploys hub and spoke environments in two Azure regions (East US 2 and Central US) and connects them via ExpressRoute using Azure Route Server to manage routing. Includes an OPNSense-based on-premises branch and tests cross-region routing behavior.

**Key scripts:**
- [1-deploy-hubs.azcli](./multi-region-er-ars/1-deploy-hubs.azcli) – Deploys Hub1 and Hub2 with ExpressRoute gateways
- [2-deploy-opn-hub.azcli](./multi-region-er-ars/2-deploy-opn-hub.azcli) – Deploys OPNSense NVA in the hub
- [3-deploy-branch.azcli](./multi-region-er-ars/3-deploy-branch.azcli) – Deploys on-premises branch environment
- [4-onprem-gcp.azcli](./multi-region-er-ars/4-onprem-gcp.azcli) – Sets up GCP on-premises via partner interconnect

---

## 10. SD-WAN with Traffic Inspection

**Folder:** [sd-wan-inspection](./sd-wan-inspection/)

Deploys a hub and spoke environment where OPNSense acts as an SD-WAN NVA. Traffic from branches is forwarded to the hub and inspected by a next-hop firewall load balancer (NHFW LB). Demonstrates traffic steering and inspection integration in a hub and spoke design.

**Key scripts:**
- [1-hub-sdwan-fw.azcli](./sd-wan-inspection/1-hub-sdwan-fw.azcli) – Deploys hub, spokes, and SD-WAN/firewall NVAs
- [2-branch.azcli](./sd-wan-inspection/2-branch.azcli) – Deploys branch environment
- [3-dc.azcli](./sd-wan-inspection/3-dc.azcli) – Deploys data center environment
- [4-scenario1-sdwan-nhfwlb.azcli](./sd-wan-inspection/4-scenario1-sdwan-nhfwlb.azcli) – Configures SD-WAN with next-hop firewall load balancer

---

## 11. Single Region VPN + ExpressRoute Coexistence

**Folder:** [single-region-vpn-er](./single-region-vpn-er/)

Deploys a hub and spoke topology with both a VPN gateway and an ExpressRoute gateway coexisting in a single Azure region. Useful for testing routing behavior and failover when both connectivity options are present.

**Key scripts:**
- [azure-deploy.azcli](./single-region-vpn-er/azure-deploy.azcli) – Deploys Azure hub, spokes, and both gateways
- [gcp-er.azcli](./single-region-vpn-er/gcp-er.azcli) – Sets up GCP partner interconnect for ExpressRoute

---

## 12. Vendor VNET with Azure Route Server

**Folder:** [vendor-vnet-ars](./vendor-vnet-ars/)

Deploys a scenario where a third-party SD-WAN vendor VNET uses Azure Route Server (ARS) to exchange routes with the Azure hub. OPNSense is used as the NVA in the vendor transit VNET, with separate vendor1 and vendor2 VNETs peering into the solution.

**Key scripts:**
- [1-hub-sdwan-fw.azcli](./vendor-vnet-ars/1-hub-sdwan-fw.azcli) – Deploys hub, spokes, and firewall NVA
- [2-vendor-transit.azcli](./vendor-vnet-ars/2-vendor-transit.azcli) – Deploys vendor transit VNET with OPNSense and ARS
- [3-branch.azcli](./vendor-vnet-ars/3-branch.azcli) – Deploys branch environment
- [4-dc.azcli](./vendor-vnet-ars/4-dc.azcli) – Deploys data center environment

---

## 13. Third-Party VNET Integration with ExpressRoute

**Folder:** [vendor-vnet-er](./vendor-vnet-er/)

Covers integration scenarios for third-party vendor VNETs connected to the hub via ExpressRoute. Includes both static routing and BGP-based routing configurations to support vendor appliance deployments.

**Key scripts:**
- [deploy.azcli](./vendor-vnet-er/deploy.azcli) – Deploys the full environment
- [onprem-gcp.sh](./vendor-vnet-er/onprem-gcp.sh) – Deploys GCP on-premises side
- [validate.azcli](./vendor-vnet-er/validate.azcli) – Validates routing and connectivity

---

## 14. VNET with Azure Route Server, ExpressRoute, and OPNSense

**Folder:** [vnet-ars-er-opn](./vnet-ars-er-opn/)

Deploys a branch VNET using OPNSense as a network virtual appliance, connected back to the hub via Azure Route Server and an ExpressRoute circuit. Demonstrates how ARS enables dynamic route exchange between the NVA and ExpressRoute gateway.

**Key scripts:**
- [deploy.azcli](./vnet-ars-er-opn/deploy.azcli) – Deploys branch VNET with OPNSense and ARS
- [connect-er.azcli](./vnet-ars-er-opn/connect-er.azcli) – Connects the ExpressRoute circuit
- [linux.azcli](./vnet-ars-er-opn/linux.azcli) – Deploys Linux VMs for validation

---

## 15. IPSec VPN over ExpressRoute (Hub and Spoke)

**Folder:** [vpner-hub-spoke](./vpner-hub-spoke/)

Deep dive into IPSec/IKE VPN tunnels established over the ExpressRoute private peering. Includes a hub and spoke environment in Azure and an on-premises network emulated using OPNSense. The second part covers how Azure Route Server hub routing preference manages routing when the same prefix is advertised via both ExpressRoute and VPN.

**Key scripts:**
- [1-deploy-hubspk.azcli](./vpner-hub-spoke/1-deploy-hubspk.azcli) – Deploys Azure hub and spoke
- [2-deploy-branch.azcli](./vpner-hub-spoke/2-deploy-branch.azcli) – Deploys on-premises branch with OPNSense
- [3-deploy-nva-lnx.azcli](./vpner-hub-spoke/3-deploy-nva-lnx.azcli) – Deploys Linux NVA variant
- [3-deploy-nva-windows.azcli](./vpner-hub-spoke/3-deploy-nva-windows.azcli) – Deploys Windows NVA variant
- [4-connect-ervpn-bgp.azcli](./vpner-hub-spoke/4-connect-ervpn-bgp.azcli) – Connects ER+VPN with BGP routing
- [4-connect-ervpn-static.azcli](./vpner-hub-spoke/4-connect-ervpn-static.azcli) – Connects ER+VPN with static routing
- [4-validation.azcli](./vpner-hub-spoke/4-validation.azcli) – Validates routing and connectivity
