variable "resource_group_name" {
  type        = string
  description = "Name of the resource group that contains the hub resources."
}

variable "location" {
  type        = string
  description = "Azure region for the hub resources."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to hub resources."
  default     = {}
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
    gateway_subnet_extra_prefix = string
  })
  description = "Hub VNet and subnet address plan."

  validation {
    condition     = contains([for subnet in var.hub.subnets : subnet.name], "GatewaySubnet")
    error_message = "hub.subnets must include a subnet named exactly GatewaySubnet."
  }

  validation {
    condition     = contains([for subnet in var.hub.subnets : subnet.name], "RouteServerSubnet")
    error_message = "hub.subnets must include a subnet named exactly RouteServerSubnet."
  }

  validation {
    condition     = contains([for subnet in var.hub.subnets : subnet.name], "AzureBastionSubnet")
    error_message = "hub.subnets must include a subnet named exactly AzureBastionSubnet."
  }

  validation {
    condition     = contains([for subnet in var.hub.subnets : subnet.name], "AzureFirewallSubnet")
    error_message = "hub.subnets must include a subnet named exactly AzureFirewallSubnet."
  }

  validation {
    condition     = contains([for subnet in var.hub.subnets : subnet.name], "subnet1")
    error_message = "hub.subnets must include a subnet named exactly subnet1."
  }

  validation {
    condition = contains(
      flatten([for subnet in var.hub.subnets : subnet.name == "GatewaySubnet" ? subnet.address_prefixes : []]),
      var.hub.gateway_subnet_extra_prefix
    )
    error_message = "GatewaySubnet address_prefixes must include hub.gateway_subnet_extra_prefix."
  }
}

variable "admin_username" {
  type        = string
  description = "Admin username for the hub VM."
}

variable "admin_password" {
  type        = string
  description = "Admin password for the hub VM."
  sensitive   = true
}

variable "vm_size" {
  type        = string
  description = "Azure VM size for the hub VM."
}

variable "deploy_bastion" {
  type        = bool
  description = "Whether to deploy Azure Bastion in AzureBastionSubnet."
}

variable "ssh_source_address_prefix" {
  type        = string
  description = "Source address prefix allowed to SSH to the hub VM."
  default     = "*"
}
