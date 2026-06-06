# Manual Megaport cross-connect and key exchange

This lab connects an Azure ExpressRoute private peering circuit to a GCP Partner Interconnect VLAN attachment through Megaport as the cross-connect fabric. The intended lab routing is Azure hub `10.0.0.0/24` to GCP "on-prem" `192.168.100.0/24` using BGP across:

- Azure ExpressRoute gateway ASN: `65515`
- Azure ExpressRoute circuit / Microsoft edge ASN: `12076`
- Megaport/provider router ASN: `65001`
- GCP Cloud Router ASN: `16550`

## Why this is manual

Terraform can create the Azure ExpressRoute circuit and the GCP Partner Interconnect VLAN attachment, but the provider cross-connect still requires credentialed Megaport portal work, exchange of provider-specific keys, location/edge-domain choices, and acknowledgement of real Megaport/Azure/GCP billing. Do not treat this as a dry-run-only step.

## Prerequisites

- Megaport account with portal access and permission to create VXCs.
- Azure ExpressRoute circuit provisioned by Terraform in Chicago, 50 Mbps, Standard/Metered, with Megaport as the provider.
- GCP Partner Interconnect VLAN attachment created by Terraform and associated with the target Cloud Router.
- Azure CLI and Google Cloud CLI installed and authenticated for read-only verification by an operator.
- Confirm current requirements in the official docs:
  - Azure ExpressRoute overview and routing: <https://learn.microsoft.com/azure/expressroute/expressroute-introduction>, <https://learn.microsoft.com/azure/expressroute/expressroute-routing>
  - GCP Partner Interconnect provisioning: <https://cloud.google.com/network-connectivity/docs/interconnect/how-to/partner/provisioning-overview>

## Manual steps

1. Get the Azure ExpressRoute circuit service key.

   Replace the placeholders with the Terraform-created resource group and circuit name:

   ```bash
   az network express-route show \
     --resource-group <azure-resource-group> \
     --name <expressroute-circuit-name> \
     --query serviceKey \
     --output tsv
   ```

2. Get the GCP Partner Interconnect VLAN attachment pairing key.

   Replace the placeholders with the Terraform-created attachment name, region, and project:

   ```bash
   gcloud compute interconnects attachments describe <vlan-attachment-name> \
     --region <gcp-region> \
     --project <gcp-project-id> \
     --format="value(pairingKey)"
   ```

3. Create the Megaport VXCs in the Megaport portal.

   - Create the Azure VXC for the ExpressRoute circuit using the Azure ExpressRoute service key.
   - Create the GCP VXC for Partner Interconnect using the GCP VLAN attachment pairing key.
   - Select the Chicago market/location and the intended edge availability domain for the lab.
   - Set the VXC rate limit to approximately `50 Mbps` so it matches the lab ExpressRoute circuit bandwidth.
   - Review all recurring and usage charges before submitting, because this step can activate real billing.

4. Wait for provider-side provisioning to complete.

   - Azure ExpressRoute circuit provider state should become `Provisioned`:

     ```bash
     az network express-route show \
       --resource-group <azure-resource-group> \
       --name <expressroute-circuit-name> \
       --query serviceProviderProvisioningState \
       --output tsv
     ```

   - GCP VLAN attachment should become `ACTIVE`:

     ```bash
     gcloud compute interconnects attachments describe <vlan-attachment-name> \
       --region <gcp-region> \
       --project <gcp-project-id> \
       --format="value(state)"
     ```

5. Verify BGP comes up.

   Confirm that the Azure ExpressRoute private peering and GCP Cloud Router BGP sessions are established, and that expected routes are learned/advertised between Azure hub `10.0.0.0/24` and GCP "on-prem" `192.168.100.0/24`.

## Redundancy and BFD

This lab uses a single ExpressRoute circuit, single GCP Partner Interconnect attachment, and a single peering location/path through Megaport. That is lab-only and should not be treated as an SLA-capable production topology. Production designs should use redundant circuits/VXCs, diverse edge availability domains or locations, deterministic route policy, and Bidirectional Forwarding Detection (BFD) where supported for faster BGP failure detection.

## Verification checklist

- [ ] Azure ExpressRoute circuit `serviceProviderProvisioningState` is `Provisioned`.
- [ ] GCP Partner Interconnect VLAN attachment state is `ACTIVE`.
- [ ] Azure ExpressRoute private peering BGP peer status is up/established.
- [ ] GCP Cloud Router status shows the BGP peer established.
- [ ] GCP Cloud Router learned routes include the Azure hub prefix `10.0.0.0/24`.
- [ ] Azure learned/propagated routes include the GCP "on-prem" prefix `192.168.100.0/24`.
- [ ] Route filters avoid unintended default-route or broad-prefix advertisement.
- [ ] BFD and dual-path redundancy gaps are documented before any production reuse.

> Analysis only — verify against vendor documentation before applying.
