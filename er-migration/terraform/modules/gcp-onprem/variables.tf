variable "project" {
  description = "Google Cloud project ID used for the simulated on-premises resources."
  type        = string
}

variable "region" {
  description = "Google Cloud region for the subnet, Cloud Router, and Partner Interconnect VLAN attachment."
  type        = string
}

variable "zone" {
  description = "Google Cloud zone for the simulated on-premises VM."
  type        = string
}

variable "gcp_onprem" {
  description = "Configuration for the GCP-hosted simulated on-premises site."
  type = object({
    deploy_gcp       = bool
    network_name     = string
    network_cidr     = string
    subnet_cidr      = string
    vm_private_ip    = string
    cloud_router_asn = number
  })

  validation {
    condition     = can(cidrnetmask(var.gcp_onprem.network_cidr)) && can(cidrnetmask(var.gcp_onprem.subnet_cidr))
    error_message = "gcp_onprem.network_cidr and gcp_onprem.subnet_cidr must be valid IPv4 CIDR ranges."
  }
}

variable "allowed_source_ranges" {
  description = "CIDR ranges allowed by the simulated on-premises ingress firewall for TCP, UDP, and ICMP."
  type        = list(string)
  default     = ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "35.235.240.0/20"]

  validation {
    condition     = alltrue([for cidr in var.allowed_source_ranges : can(cidrnetmask(cidr))])
    error_message = "allowed_source_ranges must contain only valid IPv4 CIDR ranges."
  }
}
