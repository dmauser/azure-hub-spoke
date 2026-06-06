variable "resource_group_name" {
  type        = string
  description = "Name of the resource group that contains the spoke resources."
}

variable "location" {
  type        = string
  description = "Azure region for the spoke resources."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to spoke resources."
  default     = {}
}

variable "name" {
  type        = string
  description = "Name of the spoke virtual network."
}

variable "address_space" {
  type        = list(string)
  description = "Address space for the spoke virtual network."
}

variable "subnets" {
  type = list(object({
    name             = string
    address_prefixes = list(string)
    vm_private_ip    = string
  }))
  description = "Spoke subnets; the first subnet hosts the spoke VM."

  validation {
    condition     = length(var.subnets) > 0
    error_message = "At least one spoke subnet is required."
  }
}

variable "vm_size" {
  type        = string
  description = "Azure VM size for the spoke VM."
}

variable "admin_username" {
  type        = string
  description = "Admin username for the spoke VM."
}

variable "admin_password" {
  type        = string
  description = "Admin password for the spoke VM."
  sensitive   = true
}

variable "hub_vnet_id" {
  type        = string
  description = "ID of the hub virtual network."
}

variable "hub_vnet_name" {
  type        = string
  description = "Name of the hub virtual network."
}

variable "hub_resource_group_name" {
  type        = string
  description = "Name of the resource group containing the hub virtual network."
}

variable "ssh_source_address_prefix" {
  type        = string
  description = "Source address prefix allowed to SSH to the spoke VM."
  default     = "*"
}
