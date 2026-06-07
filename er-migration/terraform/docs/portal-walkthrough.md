# Portal walkthrough (learning by doing)

This is a portal-first, click-through version of the ExpressRoute migration lab. Instead of running
Terraform, you build every piece by hand in the Azure portal (and the GCP and Megaport portals),
then perform the **managed ExpressRoute gateway migration** at the end. The goal is to *understand*
each component; the [Terraform path in the README](../../README.md) remains the fastest way to stand
up or tear down the same lab.

> Portal UI labels change over time. Each section links to the official documentation — follow the
> docs if a screen differs from what is described here.

## What you will build

The same topology the Terraform code deploys:

| Network | CIDR | Purpose |
| --- | --- | --- |
| `az-hub-vnet` | `10.0.0.0/24` | Azure hub VNet |
| `az-hub-vnet/subnet1` | `10.0.0.0/27` | Hub VM subnet (VM `10.0.0.4`) |
| `az-hub-vnet/GatewaySubnet` | `10.0.0.64/26` | ExpressRoute gateway subnet — name must be exactly `GatewaySubnet`, sized `/26` so the temporary second gateway from managed migration fits |
| `az-hub-vnet/AzureBastionSubnet` | `10.0.0.192/26` | Azure Bastion subnet — name must be exactly `AzureBastionSubnet` |
| `az-spk1-vnet` | `10.0.1.0/24` | Spoke 1 (VM `10.0.1.4`) |
| `az-spk2-vnet` | `10.0.2.0/24` | Spoke 2 (VM `10.0.2.4`) |
| `gcp-on-prem-vpc` | `192.168.100.0/24` | GCP simulated on-premises (VM `192.168.100.2`) |

ASNs: Azure ExpressRoute gateway `65515`, ExpressRoute circuit/Microsoft edge `12076`, Megaport/provider
router `65001`, GCP Cloud Router `16550`.

---

## Step 1 — Resource group

1. Azure portal → search **Resource groups** → **+ Create**.
2. Name `lab-er-migration`, choose a region (the lab used `westus3`), **Review + create**.

Docs: [Manage resource groups](https://learn.microsoft.com/azure/azure-resource-manager/management/manage-resource-groups-portal).

## Step 2 — Hub VNet and subnets

1. Search **Virtual networks** → **+ Create** → resource group `lab-er-migration`, name `az-hub-vnet`.
2. **IP addresses** tab → set address space `10.0.0.0/24` and add these subnets:
   - `subnet1` → `10.0.0.0/27`
   - `GatewaySubnet` → `10.0.0.64/26` (use the **Add gateway subnet** option; the name is fixed)
   - `AzureBastionSubnet` → `10.0.0.192/26` (use the **Add Azure Bastion subnet** option)
3. **Review + create**.

Docs: [Create a virtual network](https://learn.microsoft.com/azure/virtual-network/quick-create-portal).

## Step 3 — Spoke VNets

Repeat Step 2 for the two spokes (only `subnet1` each):

- `az-spk1-vnet` → `10.0.1.0/24`, `subnet1` `10.0.1.0/27`
- `az-spk2-vnet` → `10.0.2.0/24`, `subnet1` `10.0.2.0/27`

## Step 4 — Virtual machines

Create three small Ubuntu VMs (one per VNet) so you can test connectivity later:

1. Search **Virtual machines** → **+ Create** → **Azure virtual machine**.
2. Hub VM: resource group `lab-er-migration`, image **Ubuntu Server LTS**, place it in `az-hub-vnet/subnet1`,
   set a static private IP `10.0.0.4`. Use password or SSH-key auth (note the credentials for Bastion login).
3. Repeat for spoke VMs in `az-spk1-vnet/subnet1` (`10.0.1.4`) and `az-spk2-vnet/subnet1` (`10.0.2.4`).
4. To save cost, give them no public IP — you reach them through Bastion.

Docs: [Create a Linux VM in the portal](https://learn.microsoft.com/azure/virtual-machines/linux/quick-create-portal).

## Step 5 — Azure Bastion (hub)

1. Open `az-hub-vnet` → **Bastion** → **Deploy Bastion**.
2. It uses the `AzureBastionSubnet` you created in Step 2. Create it and wait for provisioning.
3. Once ready, open any VM → **Connect** → **Bastion** and sign in with the VM credentials.

Docs: [Deploy Bastion](https://learn.microsoft.com/azure/bastion/quickstart-host-portal).

## Step 6 — Hub-and-spoke peerings (gateway transit)

For each spoke, create a peering to the hub with transit so spokes can use the hub's ExpressRoute gateway:

1. Open `az-hub-vnet` → **Peerings** → **+ Add**.
2. This peering link name (hub→spoke): allow forwarded traffic, and select **Allow gateway transit**.
3. Remote peering link name (spoke→hub): select **Use the remote virtual network's gateway or route server**.
4. Choose the remote VNet (`az-spk1-vnet`, then repeat for `az-spk2-vnet`) and create.

> Spokes can only **use the remote gateway** after the ExpressRoute gateway (Step 8) exists. You can create
> the peering now with the setting enabled; transit becomes effective once the gateway is provisioned.

Docs: [Create VNet peering](https://learn.microsoft.com/azure/virtual-network/virtual-network-manage-peering)
· [Hub-spoke topology](https://learn.microsoft.com/azure/architecture/networking/architecture/hub-spoke).

## Step 7 — ExpressRoute circuit (get the service key)

1. Search **ExpressRoute circuits** → **+ Create**.
2. **Basics**: subscription, resource group `lab-er-migration`, name `az-hub-er-circuit`, choose the
   peering-location **region** of your provider.
3. **Configuration**: **Port type** = Provider, **Provider** = **Megaport**, **Peering location** =
   the Megaport metro you will use (the lab used Chicago), **Bandwidth** = `50 Mbps`, **SKU** = Standard,
   **Billing model** = Metered.
4. **Review + create**.
5. After it deploys, open the circuit **Overview** and copy the **Service key** — you give this to
   Megaport. The **Provider status** starts as **Not provisioned**.

Docs: [Create an ExpressRoute circuit (portal)](https://learn.microsoft.com/azure/expressroute/expressroute-howto-circuit-portal-resource-manager).

## Step 8 — ExpressRoute virtual network gateway

1. Search **Virtual network gateways** → **+ Create**.
2. **Gateway type** = **ExpressRoute**, name `az-hub-ergw`, choose a **SKU** (the lab uses `Standard`),
   virtual network `az-hub-vnet` (it uses the `GatewaySubnet`).
3. For an ExpressRoute-type gateway, Azure **manages the public IP internally** — you do not configure
   BGP settings here; the gateway uses ASN `65515`.
4. **Review + create**. Provisioning can take ~30–45 minutes.

Docs: [Create an ExpressRoute gateway](https://learn.microsoft.com/azure/expressroute/expressroute-howto-add-gateway-portal-resource-manager)
· [About ExpressRoute gateways](https://learn.microsoft.com/azure/expressroute/expressroute-about-virtual-network-gateways).

## Step 9 — GCP simulated on-premises (Google Cloud console)

⚠️ GCP steps are not verified against Microsoft docs — confirm against the
[GCP documentation](https://cloud.google.com/network-connectivity/docs/interconnect/how-to/partner/provisioning-overview).

1. Google Cloud console → **VPC network** → **Create VPC network** → name `gcp-on-prem-vpc`, custom mode,
   one subnet `192.168.100.0/24` in your chosen region (the lab used `us-east1`).
2. **Firewall**: allow internal traffic and SSH/ICMP for testing.
3. **Compute Engine** → create an `e2-micro` VM with internal IP `192.168.100.2`.
4. **Hybrid Connectivity → Cloud Routers** → create a Cloud Router with BGP ASN `16550`.
5. **Hybrid Connectivity → VLAN attachments** → create a **Partner** Interconnect VLAN attachment bound to
   that Cloud Router. Copy the **pairing key** it generates — you give this to Megaport.

## Step 10 — Megaport cross-connect (Megaport portal)

⚠️ Megaport steps are not verified against Microsoft docs — confirm against the
[Megaport documentation](https://docs.megaport.com/).

Follow the lab's dedicated guide: **[Manual Megaport cross-connect and key exchange](./megaport-cross-connect.md)**.
In short:

1. Create the **Azure VXC** using the ExpressRoute **service key** (Step 7).
2. Create the **GCP VXC** using the Partner Interconnect **pairing key** (Step 9).
3. Match metro/location and set the rate limit to ~`50 Mbps`.
4. Wait until the Azure circuit **Provider status** becomes **Provisioned** and the GCP attachment becomes **ACTIVE**.

## Step 11 — ExpressRoute private peering

Only after the circuit **Provider status** is **Provisioned**:

1. Open `az-hub-er-circuit` → **Peerings** → **Azure private**.
2. Provide a **VLAN ID**, a **peer ASN** (`12076` for this lab's circuit side), and **two `/30`** point-to-point
   subnets (primary and secondary) that are not part of any VNet address space — Azure uses the second usable
   IP, your side uses the first. Do not use ASNs `65515`–`65520` for the peer ASN.
3. Save the peering.

Docs: [Create and modify peering (portal)](https://learn.microsoft.com/azure/expressroute/expressroute-howto-routing-portal-resource-manager#azure-private-peering).

## Step 12 — Gateway-to-circuit connection

1. Search **Connections** → **+ Create** → **Connection type** = **ExpressRoute**.
2. Select the virtual network gateway `az-hub-ergw` and the circuit `az-hub-er-circuit`, then create.
3. Verify BGP comes up and that Azure hub `10.0.0.0/24` and GCP `192.168.100.0/24` learn each other's routes
   (use the connection/peering route tables and a VM ping test through Bastion).

Docs: [Connect a VNet to a circuit](https://learn.microsoft.com/azure/expressroute/expressroute-howto-linkvnet-portal-resource-manager).

---

## Step 13 — Managed ExpressRoute gateway migration (the main event)

Azure's **managed gateway migration** moves you to an equal-or-higher SKU (and Basic→Standard public IP)
non-disruptively. The temporary second gateway is why `GatewaySubnet` is sized `/26` in this lab.

1. Open the gateway `az-hub-ergw` → **Migration** (or **Gateway SKU migration**).
2. **Validate** — Azure confirms all resources are in a *succeeded* state and the gateway is eligible.
   No changes are made; nothing to roll back.
3. **Prepare** — Azure creates a **new** virtual network gateway with the target configuration,
   automatically assigns a new public IP, and re-establishes connections. This can take up to ~45 minutes.
   The original gateway is locked during preparation. You can specify a custom name, or Azure appends
   `_migrated`. You can **Abort** here to delete the new gateway and keep the original.
4. **Migrate** — switch traffic from the old gateway to the new one (up to ~15 minutes; brief possible
   interruption). **Do not navigate away from the migration page** while traffic moves. You can still revert
   to the original gateway after this step.
5. **Commit** — finalize by deleting the original gateway and its connections. **After commit, the change
   cannot be rolled back.**
6. Re-validate connectivity (ping the GCP VM from a spoke VM through the gateway) after migration.

Docs: [About ExpressRoute gateway migration](https://learn.microsoft.com/azure/expressroute/gateway-migration).

---

## Verification checklist

- [ ] Bastion connects to hub and spoke VMs.
- [ ] Spokes reach the hub and (via ExpressRoute) GCP `192.168.100.0/24`.
- [ ] ExpressRoute circuit **Provider status** = **Provisioned**; GCP VLAN attachment = **ACTIVE**.
- [ ] Private peering BGP is established; routes are exchanged both directions.
- [ ] After managed migration, the new gateway is active, connectivity is intact, and (post-commit) the old
      gateway is removed.

## Clean up

Delete the `lab-er-migration` resource group in Azure, the Megaport VXCs, and the GCP resources to stop
billing. The Terraform path can do this with `terraform destroy`.

> Analysis only — verify against vendor documentation before applying.
