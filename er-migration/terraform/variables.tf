variable "rg_name" {
  type        = string
  description = "Azure resource group name for the ER migration lab."
  default     = "lab-er-migration"
}

variable "location" {
  type        = string
  description = "Azure region for lab resources."
  default     = "westus3"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to Azure resources."
  default = {
    project   = "er-migration"
    lab       = "expressroute-migration"
    managedBy = "terraform"
  }
}

variable "admin_username" {
  type        = string
  description = "Admin username for lab virtual machines."
  default     = "azureuser"
}

variable "admin_password" {
  type        = string
  description = "Admin password for lab virtual machines. Supply via tfvars or TF_VAR_admin_password."
  sensitive   = true

  validation {
    condition     = length(var.admin_password) >= 12
    error_message = "admin_password must be at least 12 characters long."
  }
}

variable "vm_size" {
  type        = string
  description = "Azure VM size for lab virtual machines."
  default     = "Standard_DS1_v2"
}

variable "deploy_bastion" {
  type        = bool
  description = "Whether to deploy Azure Bastion in the hub."
  default     = true
}

variable "gcp_project" {
  type        = string
  description = "GCP project ID for simulated on-prem resources."
  default     = ""
}

variable "gcp_region" {
  type        = string
  description = "GCP region for simulated on-prem resources."
  default     = "us-east1"
}

variable "gcp_zone" {
  type        = string
  description = "GCP zone for simulated on-prem resources."
  default     = "us-east1-b"
}

variable "hub" {
  type = object({
    name          = string
    address_space = list(string)
    subnets = list(object({
      name             = string
      address_prefixes = list(string)
      purpose          = optional(string)
    }))
  })

  default = {
    name          = "az-hub-vnet"
    address_space = ["10.0.0.0/24"]
    subnets = [
      { name = "subnet1", address_prefixes = ["10.0.0.0/27"], purpose = "hub-vm" },
      { name = "GatewaySubnet", address_prefixes = ["10.0.0.64/26"], purpose = "expressroute-gateway" },
      { name = "AzureBastionSubnet", address_prefixes = ["10.0.0.192/26"], purpose = "azure-bastion" }
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

variable "er_gateway" {
  type = object({
    name           = string
    asn            = number
    sku            = string
    routing_weight = number
  })

  default = {
    name           = "az-hub-ergw"
    asn            = 65515
    sku            = "Standard"
    routing_weight = 0
  }
}

variable "er_circuit" {
  description = <<-EOT
    ExpressRoute circuit settings plus optional Azure private peering / connection control.

    private_peering.enabled        - when true, the gateway-to-circuit connection is created.
                                     Only enable AFTER the Megaport VXC is provisioned (circuit
                                     serviceProviderProvisioningState = Provisioned), otherwise the
                                     connection fails with ServiceProviderNotProvisioned.
    private_peering.create_peering - when true (default), Terraform creates the AzurePrivatePeering.
                                     Set false when Megaport (managed provider) auto-creates the
                                     peering, so Terraform manages only the connection.
  EOT
  type = object({
    name              = optional(string, "az-hub-er-circuit")
    provider_name     = optional(string, "Megaport")
    peering_location  = optional(string, "Chicago")
    bandwidth_in_mbps = optional(number, 50)
    sku_tier          = optional(string, "Standard")
    sku_family        = optional(string, "MeteredData")
    private_peering = optional(object({
      enabled                       = optional(bool, false)
      create_peering                = optional(bool, true)
      peer_asn                      = optional(number, 65001)
      vlan_id                       = optional(number)
      primary_peer_address_prefix   = optional(string)
      secondary_peer_address_prefix = optional(string)
    }), {})
  })
  default = {}
}
