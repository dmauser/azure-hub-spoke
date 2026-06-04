# Vendor VNET with Azure Route Server (ARS)

## Overview

This lab demonstrates a **hub-spoke architecture** that integrates a third-party **vendor network** with an Azure hub using **Azure Route Server (ARS)** and **OPNsense NVAs**. The vendor network is connected via VNET peering, while a remote datacenter (DC) and branch site connect through **ExpressRoute** and **IPSec VPN** respectively.

The key scenario validates how a vendor (e.g., a managed service provider) can inject routes into the Azure hub-spoke topology using ARS, enabling end-to-end routing between vendor VNETs, Azure spokes, an on-premises DC, and a remote branch site—all with traffic inspection through firewall and SD-WAN NVAs.

## Architecture Diagram

![Lab Architecture](lab.svg)

> **Note:** Open [lab.drawio](lab.drawio) in [draw.io](https://app.diagrams.net/) for the interactive version.

## Network Topology

### Azure Hub (10.0.0.0/24)

| Component | Details |
|---|---|
| Hub VNET | `az-hub-vnet` — 10.0.0.0/24 |
| Spoke 11 | `az-spk11` — 10.0.1.0/24 (VM: 10.0.1.4) |
| Spoke 12 | `az-spk12` — 10.0.2.0/24 (VM: 10.0.2.4) |
| SD-WAN NVA | OPNsense — 10.0.0.84, ASN 65004 |
| Firewall NVA | OPNsense — 10.0.0.116, ASN 65000 |
| Azure Route Server | INT0: 10.0.0.133, INT1: 10.0.0.132, **B2B Enabled** |
| ExpressRoute GW | ERGW1 — ASN 65515 |

### Vendor Network

| Component | Details |
|---|---|
| Vendor Transit VNET | `vendor-transit-vnet` — 10.100.0.0/24 |
| Vendor ARS VNET | `vendor-ars-vnet` — 10.110.0.0/24 |
| Vendor1 VNET | `vendor1-vnet` — 172.16.1.0/24 |
| Vendor2 VNET | `vendor2-vnet` — 172.16.2.0/24 |
| Vendor NVA | OPNsense — 10.100.0.52, ASN 65100 |
| Vendor Route Server | `vendor-rs` — B2B Enabled |

### Remote Sites

| Component | Details |
|---|---|
| Branch1 | `branch1-vnet` — 10.64.0.0/24 (VM: 10.64.0.36), ASN 65010, connected via IPSec |
| DC1 | `dc1-vnet` — 10.128.0.0/24 (VM: 10.128.0.4), ASN 65128, connected via ExpressRoute |

## Key Design Patterns

### Azure Route Server with Branch-to-Branch (B2B)

- **B2B is enabled** on the hub ARS, allowing the SD-WAN NVA (ASN 65004) and Firewall NVA (ASN 65000) to exchange routes through ARS.
- The Firewall NVA advertises an aggregate `10.0.0.0/22` route, attracting spoke traffic for inspection.
- The SD-WAN NVA advertises branch routes (10.64.0.0/24) learned via IPSec tunnels.

### Vendor Integration via ARS

- The **Vendor Transit NVA** (ASN 65100) peers with **both** the vendor ARS (`vendor-rs`) and the hub ARS (`az-hub-rs`).
- Vendor VNETs (172.16.x.0/24) peer with the vendor ARS VNET using `useRemoteGateways=true`, enabling them to learn routes propagated by ARS.
- The Vendor Transit VNET peers with the Azure Hub VNET using `useRemoteGateways=true` to learn routes from the hub's ExpressRoute Gateway.
- The Vendor NVA advertises RFC 1918 routes to vendor VNETs, providing reachability to Azure and on-premises networks.

### SD-WAN to Branch Connectivity

- Branch1 runs an OPNsense NVA that establishes an **IPSec tunnel** to the hub's SD-WAN NVA.
- A UDR on the branch VM subnet sends all traffic (0.0.0.0/0) through the branch NVA.

### ExpressRoute to DC

- Two ExpressRoute circuits connect the Azure Hub (via `az-hub-ergw`) and DC1 (via `dc1-ergw`).
- DC1 has its own ARS and OPNsense NVA (ASN 65128) for route propagation.

## Deployment Scripts

Deploy the scripts **in order**:

| # | Script | Description |
|---|---|---|
| 1 | [1-hub-sdwan-fw.azcli](1-hub-sdwan-fw.azcli) | Deploys the Azure Hub, 2 Spokes, VMs, ExpressRoute Gateway, ARS, SD-WAN NVA, and Firewall NVA. Peers NVAs with ARS and enables B2B. |
| 2 | [2-vendor-transit.azcli](2-vendor-transit.azcli) | Deploys the Vendor Transit VNET, Vendor ARS VNET, Vendor1/2 VNETs with VMs, Vendor NVA, Vendor Route Server. Creates all VNET peerings and peers NVA with both route servers. |
| 3 | [3-branch.azcli](3-branch.azcli) | Deploys Branch1 VNET with VM and OPNsense NVA. Creates NSG rules, UDR for default route via NVA. |
| 4 | [4-dc.azcli](4-dc.azcli) | Deploys DC1 hub with 2 spokes, VMs, ExpressRoute Gateway, ARS, and OPNsense NVA. Creates two ExpressRoute circuits and connects them to gateways. |
| — | [vmtools.azcli](vmtools.azcli) | Enables boot diagnostics and installs networking tools (traceroute, tcptraceroute, iperf) on all VMs. |

### OPNsense Configurations

Pre-built OPNsense XML configurations are in the [`opnconfig/`](opnconfig/) directory:

| Config File | NVA |
|---|---|
| `config-az-hub-sdwan1.xml` | Hub SD-WAN NVA |
| `config-vendor-transit-opnnva1.xml` | Vendor Transit NVA |
| `config-branch1-opnnva.xml` | Branch1 NVA |
| `config-dc1-opnnva.xml` | DC1 NVA |

## Prerequisites

- Azure CLI (`az`) installed and authenticated
- An Azure subscription with sufficient quota for VMs, VNETs, ExpressRoute circuits, and Route Servers
- ExpressRoute circuits require provider provisioning (Megaport, Chicago peering location)

## Parameters

| Parameter | Default Value |
|---|---|
| Resource Group | `lab-vendor-ars` |
| Location | `southcentralus` |
| VM Username | `azureuser` |
| VM Size | `Standard_DS1_v2` |

## BGP ASN Summary

| Component | ASN |
|---|---|
| Azure Route Server (Hub & Vendor) | 65515 |
| Hub Firewall NVA | 65000 |
| Hub SD-WAN NVA | 65004 |
| Vendor Transit NVA | 65100 |
| DC1 NVA | 65128 |
| Branch1 NVA | 65010 / 65065 |
| ExpressRoute MSEE | 12076 |
