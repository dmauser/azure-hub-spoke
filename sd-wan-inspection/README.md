# SD-WAN Inspection with Azure Firewall/NVA, Azure Route Server and UDRs

This lab explores how to insert an **SD-WAN appliance pair** and a **firewall/NVA** into the
traffic path of an Azure hub-and-spoke network, and how routing changes as you progressively
introduce **Azure Route Server (ARS)** to replace static User-Defined Routes (UDRs).

The companion file [`diagram.drawio`](./diagram.drawio) contains **five pages**, each describing a
distinct routing scenario. This README explains what each page shows, the role of ARS, and how the
designs differ.

> **Analysis only** — this document describes a lab topology. Validate every design against the
> official Azure documentation linked at the bottom before applying to any environment.

---

## Lab topology (common to all scenarios)

| Component | Address | ASN / Notes |
|-----------|---------|-------------|
| **Hub VNet** | `10.0.0.0/24` | Contains Firewall/NVA, SD-WAN appliances, ARS, ER Gateway |
| **Spoke1** (`spk1-lxvm`) | `10.0.1.0/24` — VM `10.0.1.4` | Peered to hub |
| **Spoke2** (`spk2-lxvm`) | `10.0.2.0/24` — VM `10.0.2.4` | Peered to hub |
| **SD-WAN appliances** (`SDW1`/`SDW2`) | `10.0.0.80/28` (INT1 `.84`, INT2 `.85`) | ASN **65004** |
| **SD-WAN Load Balancer** (`LBFW`/`SDWLB`) | `10.0.0.118` | AS **65000** (front-ends the SD-WAN pair) |
| **Firewall / NVA** | Hub | Inline inspection device |
| **Azure Route Server (ARS1)** | INT0 `10.0.0.133`, INT1 `10.0.0.132` | ASN **65515** (fixed by Azure) |
| **ExpressRoute Gateway (ERGW1)** | Hub | ASN **65515** |
| **MSEE / Provider** | — | MSEE ASN **12076**, Provider ASN **65001** |
| **Branch1** (on-prem) | `10.64.0.0/24` — VM `10.64.0.36` | ASN **65010** |
| **DC1** (on-prem) | `10.128.0.0/24` — VM `10.128.0.4` | ASN **65128** |

**Key concepts used throughout:**

- **SD-WAN Overlay** — tunnel between the SD-WAN appliances and remote sites (Branch1, DC1) carrying
  Internet/ExpressRoute breakout routes.
- **Overlay between FW and SD-WAN** — a tunnel/peering between the firewall and the SD-WAN devices
  that eliminates the need for a UDR on the SD-WAN subnet itself.
- **Azure Route Server (ARS)** — injects BGP-learned routes from the firewall/NVA into the VNet so
  that effective routes are programmed dynamically instead of via static UDRs.
- **`Use Remote Gateway` peering** — spoke peerings use the hub's gateway (ER/ARS) for transit.

---

## Scenario 1 — `Scenario1-UDR-Only`

**Goal:** Force all traffic through the firewall, then through the SD-WAN pair, using **only static
UDRs** (no Azure Route Server in the data path).

- Every subnet (GatewaySubnet, Hub, SD-WAN, Spokes) has a route table that overrides VNet-peering
  **system routes** and points prefixes (`10.0.1.0/24`, `10.0.2.0/24`, `10.0.0.0/24`) **to the
  firewall**.
- `RT-SDWAN`, `RT-Hub`, `RT-SPK` all **disable BGP propagation** and send `Default (0/0)` or the
  RFC1918 supernets to the SD-WAN load balancer (`LBFW`).
- `RT-FW` sends `0/0` / RFC1918 to the SD-WAN LB and performs a next-hop **re-write** toward `SDW1`.

**Why UDRs everywhere?**
- *SD-WAN devices* and *hub-lxvm* need to override the VNet-peering system routes.
- Spokes need UDRs so that routes learned by the SD-WAN are **not** picked up via peering in a way
  that bypasses the firewall.

**Takeaway:** Works, but it is **UDR-heavy and static**. Every prefix change requires manual route
table edits. The "Overlay between FW and SD-WAN" is what removes the need for a UDR *on the SD-WAN
subnet*.

---

## Scenario 2 — `Scenario2-ARS+UDR`

**Goal:** Introduce **Azure Route Server** (`B2B = Enabled`) alongside the existing UDRs.

- ARS is deployed (INT0 `10.0.0.133`, INT1 `10.0.0.132`) with **branch-to-branch (B2B) enabled**,
  so routes can be exchanged between the NVA/firewall and the ExpressRoute gateway.
- The UDR design is essentially the **same as Scenario 1** (`RT-SDWAN`, `RT-Hub`, `RT-SPK` still
  override system routes and disable BGP propagation).
- **Important limitation called out on the page:** the **firewall advertises *None*** via BGP —
  *you cannot override VNet-peering system routes with BGP*. That is why UDRs are still required even
  though ARS is present.

**Takeaway:** Simply adding ARS does **not** remove the UDRs. BGP/ARS cannot beat a VNet system
route, so static UDRs remain mandatory to steer intra-VNet/peering traffic to the firewall.

---

## Scenario 2b — `NextHop Scenario2-ARS+UDR`

**Goal:** Same topology as Scenario 2 but uses **ARS "Next Hop IP" support** (`B2B = Disabled`) to
reduce the UDRs.

- The **SD-WAN advertises overlay routes (Internet/ER) into ARS with a route-map setting the next
  hop to the firewall LB (`FWLB`)**. The SD-WAN in turn **learns** the hub and spoke VNet prefixes.
- Because spokes can now **enable BGP propagation** and receive the ARS-learned routes (next hop =
  `LBFW`), the spoke route table (`RT-SPK`) shrinks to just `10.0.0.0/24 -> FW` to override the one
  system route that BGP can't.
- `RT-FW` still disables propagation and rewrites RFC1918 toward the SD-WAN LB / SD-WAN.
- A **`Hub-VM-consideration`** note flags that `hub-lxvm` still needs its own UDR (`RT-Hub`) to
  override peering system routes.

**Takeaway:** ARS **Next Hop IP** lets BGP-learned routes carry a custom next hop (the firewall LB),
so spokes can rely on **BGP propagation** instead of long static UDR lists — but you still keep a
minimal UDR to override same-VNet/peering system routes.

---

## Scenario 3 — `Scenario3-SD-VNET+UDR`

**Goal:** Move the SD-WAN appliances out of the hub into a **dedicated SD-WAN VNet**
(`10.20.0.0/24`) and keep some UDRs.

- **SD-WAN appliances now live in `10.20.0.0/24`** (INT1 `10.20.0.4`, INT2 `10.20.0.5`, ASN 65004).
- The former `hub-lxvm` becomes **Spoke3 (Shared Services)** `spk3-lxvm` in `10.0.3.0/24`.
- The **firewall advertises a summary to ARS** — `0.0.0.0/0` *or* `10.0.0.0/8` *or* an RFC1918
  summary *or* `10.0.0.0/22` — with **next hop = `LBFW`**.
- The SD-WAN advertises the on-prem prefixes (`10.128.0.0/24`, `10.64.0.0/24`) and runs **BGP
  peering at the OS level**, with **filters**: `No_Advertise` community outbound, inbound `AS 12076`.
- `RT-FW`, `RT-SPK`, `RT-SDWAN` still exist (default/RFC1918 to `LBFW`) — hence **"+UDR"**.
- The SD-WAN VNet peering uses **`Use Remote Gateway = Disabled`** (it has its own path), while the
  spokes use **`Use Remote Gateway = Enabled`**.

**Takeaway:** Separating the SD-WAN into its own VNet isolates the appliance lifecycle and lets the
firewall advertise a clean summary into ARS, while a smaller set of UDRs handles the cases BGP can't.

---

## Scenario 4 — `Scenario4-SD-VNET-No-UDR`

**Goal:** The target/end-state — SD-WAN in a dedicated VNet and **no UDRs** (fully BGP/ARS-driven).

- Same dedicated **SD-WAN VNet `10.20.0.0/24`** and **Spoke3 shared-services** layout as Scenario 3.
- The firewall still **advertises the summary (`0/0` / `10.0.0.0/8` / RFC1918 / `10.0.0.0/22`) to
  ARS with next hop `LBFW`**, and the SD-WAN advertises on-prem prefixes — all via **BGP**.
- Introduces a **second Route Server (`ARS2`, ASN 65515) in an `ARS-VNET`**, so the SD-WAN VNet has
  its own ARS for dynamic route exchange.
- **No route tables (UDRs) remain** — effective routes are programmed entirely through ARS + BGP,
  using **Next Hop IP** so the firewall LB stays in the path.

**Takeaway:** This is the cleanest design: routing is fully dynamic. Adding/removing prefixes is
handled by BGP advertisement and ARS injection rather than manual UDR edits. It depends on ARS
**Next Hop IP** support and per-VNet ARS instances.

---

## Scenario comparison

| Scenario | SD-WAN location | Azure Route Server | UDRs | Primary mechanism |
|----------|-----------------|--------------------|------|-------------------|
| 1 — UDR-Only | Hub | None in path | Heavy (every subnet) | Static UDRs to FW → SD-WAN LB |
| 2 — ARS+UDR | Hub | Yes (B2B enabled) | Heavy (BGP can't override system routes) | UDRs + ARS for hybrid routes |
| 2b — NextHop ARS+UDR | Hub | Yes (Next Hop IP, B2B disabled) | Minimal (one override per VNet) | BGP propagation + ARS Next Hop IP |
| 3 — SD-VNET+UDR | Dedicated VNet `10.20.0.0/24` | Yes | Some | FW summary into ARS + reduced UDRs |
| 4 — SD-VNET-No-UDR | Dedicated VNet `10.20.0.0/24` | Yes (per-VNet ARS1 + ARS2) | None | Fully BGP/ARS-driven, Next Hop IP |

**The narrative across the five pages:** start with all-static UDRs → add ARS (but discover UDRs are
still needed because BGP can't beat system routes) → use ARS **Next Hop IP** to shrink the UDRs →
move SD-WAN to its own VNet → reach a **UDR-free, fully dynamic** end state.

---

## Deployment scripts

The lab is built with the Azure CLI scripts in this folder:

| Script | Purpose |
|--------|---------|
| `1-hub-sdwan-fw.azcli` | Hub + VPN gateway + two spokes, OPNsense SD-WAN pair, SD-WAN load balancer, Azure Route Server BGP peering, and the firewall NVA |
| `2-branch.azcli` | Branch1 site (OPNsense NVA, BGP, IPsec UDP 500/4500) |
| `3-dc.azcli` | DC1 site with ExpressRoute circuit, ER gateway, Route Server, and branch-to-branch enablement |
| `4-scenario1-sdwan-nhfwlb.azcli` | Scenario 1 route tables (BGP propagation disabled, RFC1918 → SD-WAN LB) |

---

## Azure Route Server (ARS) reference links

All ARS facts in this README were validated against Microsoft Learn:

- **What is Azure Route Server?** — <https://learn.microsoft.com/azure/route-server/overview>
- **ARS common use cases** — <https://learn.microsoft.com/azure/route-server/overview#common-use-cases>
- **ARS support for ExpressRoute and Azure VPN** (route exchange / branch-to-branch) — <https://learn.microsoft.com/azure/route-server/expressroute-vpn-support>
- **Next hop IP support in Azure Route Server** (advertise routes with the LB as next hop) — <https://learn.microsoft.com/azure/route-server/next-hop-ip>
- **Next hop IP — configuration requirements** — <https://learn.microsoft.com/azure/route-server/next-hop-ip#configuration-requirements>
- **Configure and manage Azure Route Server** — <https://learn.microsoft.com/azure/route-server/configure-route-server>
  - Add a BGP peer — <https://learn.microsoft.com/azure/route-server/configure-route-server#add-a-bgp-peer>
  - Configure route exchange with virtual network gateways (branch-to-branch) — <https://learn.microsoft.com/azure/route-server/configure-route-server?tabs=portal#configure-route-exchange-with-virtual-network-gateways>
- **ARS FAQ** — <https://learn.microsoft.com/azure/route-server/route-server-faq>
  - ASNs you can use (ARS uses **65515**) — <https://learn.microsoft.com/azure/route-server/route-server-faq#what-autonomous-system-numbers-asns-can-i-use>
  - Can ARS filter out routes from NVAs? — <https://learn.microsoft.com/azure/route-server/route-server-faq#can-azure-route-server-filter-out-routes-from-nvas>
- **Quickstart: Create an Azure Route Server (PowerShell)** — <https://learn.microsoft.com/azure/route-server/quickstart-create-route-server-powershell>
- **Protect Azure Route Server with Azure DDoS Protection** — <https://learn.microsoft.com/azure/route-server/tutorial-protect-route-server-ddos>
- **Azure CLI — `az network routeserver`** — <https://learn.microsoft.com/cli/azure/network/routeserver>

### Key ARS facts relevant to these scenarios

1. **ARS ASN is fixed at `65515`** and cannot be changed.
2. **Route exchange ("branch-to-branch")** lets ARS share routes between NVAs and the
   ExpressRoute/VPN gateways — this is the `B2B = Enabled/Disabled` flag on the diagram pages.
3. **ARS cannot override VNet-peering system routes** — this is *why* the early scenarios still
   require UDRs even after ARS is added.
4. **Next Hop IP support** lets an NVA advertise routes into ARS with a custom next hop (the SD-WAN
   /firewall load balancer), which is what enables the UDR reduction in Scenarios 2b and 4.

---

> Analysis only — verify against vendor documentation before applying.
