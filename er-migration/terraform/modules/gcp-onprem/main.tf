terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

locals {
  base_name = var.gcp_onprem.network_name
}

resource "google_compute_network" "onprem" {
  project                 = var.project
  name                    = var.gcp_onprem.network_name
  auto_create_subnetworks = false
  mtu                     = 1460
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "onprem" {
  project       = var.project
  name          = "${local.base_name}-subnet"
  ip_cidr_range = var.gcp_onprem.subnet_cidr
  region        = var.region
  network       = google_compute_network.onprem.self_link
}

resource "google_compute_firewall" "onprem_allow" {
  project       = var.project
  name          = "${local.base_name}-allow"
  network       = google_compute_network.onprem.self_link
  source_ranges = var.allowed_source_ranges

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }
}

resource "google_compute_instance" "onprem" {
  project      = var.project
  name         = "${local.base_name}-vm"
  machine_type = "e2-micro"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.onprem.self_link
    network_ip = var.gcp_onprem.vm_private_ip

    access_config {
      network_tier = "PREMIUM"
    }
  }
}

resource "google_compute_router" "onprem" {
  project = var.project
  name    = "${local.base_name}-router"
  region  = var.region
  network = google_compute_network.onprem.self_link

  bgp {
    asn = var.gcp_onprem.cloud_router_asn
  }
}

resource "google_compute_interconnect_attachment" "partner" {
  project                  = var.project
  name                     = "${local.base_name}-partner-attachment"
  region                   = var.region
  type                     = "PARTNER"
  edge_availability_domain = "AVAILABILITY_DOMAIN_1"
  router                   = google_compute_router.onprem.id
  admin_enabled            = true

  # Megaport VXC creation and pairing-key exchange are manual; see docs/megaport-cross-connect.md.
}
