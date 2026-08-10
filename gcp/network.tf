# Custom-mode VPC: implicit deny-all ingress / allow-all egress — zero ingress
# by default. Exactly two ingress rules exist, both targeting the "devbox"
# network tag. Adding any other ingress MUST go through code review.
resource "google_compute_network" "devbox" {
  name                    = "devbox"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "devbox" {
  name          = "devbox-${var.gcp_region}"
  region        = var.gcp_region
  network       = google_compute_network.devbox.id
  ip_cidr_range = "10.100.0.0/24"
}

# Tailscale WireGuard. Encrypted + peer-keyed: non-tailnet packets are dropped
# by the daemon, no application surface exposed. Enables direct P2P (avoids
# DERP relay) for peers behind symmetric NAT.
resource "google_compute_firewall" "tailscale_wireguard" {
  name    = "devbox-allow-wireguard"
  network = google_compute_network.devbox.name

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["devbox"]
}

# Breakglass path: SSH reachable ONLY from Google's fixed IAP range. Normal
# access is Tailscale SSH (arrives over WireGuard, not this rule). Port 22
# is never open to the internet.
resource "google_compute_firewall" "iap_ssh" {
  name    = "devbox-allow-iap-ssh"
  network = google_compute_network.devbox.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["devbox"]
}
