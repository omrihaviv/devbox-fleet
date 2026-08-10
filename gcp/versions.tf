terraform {
  required_version = ">= 1.9.0"

  # State lives in a versioned GCS bucket (created by the one-time bootstrap,
  # docs/admin-runbook.md). Backend blocks cannot interpolate variables, so
  # the org-specific bucket arrives via a partial backend config file:
  #   cp backend.hcl.example backend.hcl   # backend.hcl is gitignored
  #   terraform init -backend-config=backend.hcl
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.8"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
