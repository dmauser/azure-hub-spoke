# Hub and Spoke Lab

## Intro
This lab is designed to deploy a hub and spoke network topology in Azure. The lab will deploy a hub virtual network with a virtual network gateway and two spoke virtual networks. The lab will also deploy a virtual machine in each spoke virtual network. The lab will also deploy a virtual network gateway in the hub virtual network and establish a ExpressRoute connection between the hub virtual network and an on-premises (aka branch) network.

The lab also will deploy the emulated Azure on-premises with a virtual network gateway (VNG) and a virtual machine in the on-premises virtual network.

## Pre-requisites

- Azure Subscription
- Megaport Cloud Router (MCR).

## Lab Network Diagram

## Step to deploy the lab

1. Deploy the hub and spoke network topology in Azure.

```bash
```

2. Deploy the on-premises (Branch) network topology in Azure.

```bash
```

3. Provision ExpressRoute on the provider side (see instructions below)

4. Connect each ExpressRoute circuit to the respective virtual network gateway in Azure Hub and on the virtual network gateway.

```bash
```
