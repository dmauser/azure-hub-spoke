output "network_self_link" {
  description = "Self link of the simulated on-premises GCP VPC network."
  value       = google_compute_network.onprem.self_link
}

output "router_name" {
  description = "Name of the GCP Cloud Router attached to the simulated on-premises VPC."
  value       = google_compute_router.onprem.name
}

output "attachment_name" {
  description = "Name of the Partner Interconnect VLAN attachment."
  value       = google_compute_interconnect_attachment.partner.name
}

output "pairing_key" {
  description = "Partner Interconnect pairing key for the manual Megaport VXC exchange."
  value       = google_compute_interconnect_attachment.partner.pairing_key
  sensitive   = true
}
