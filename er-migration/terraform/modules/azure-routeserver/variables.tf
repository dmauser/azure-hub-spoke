variable "resource_group_name" {
  type        = string
  description = "Name of the resource group that contains Azure Route Server."
}

variable "location" {
  type        = string
  description = "Azure region for Azure Route Server."
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to Azure Route Server resources."
  default     = {}
}

variable "route_server_subnet_id" {
  type        = string
  description = "ID of the RouteServerSubnet."
}

variable "branch_to_branch" {
  type        = bool
  description = "Enable branch-to-branch traffic exchange on Azure Route Server."
  default     = true
}
