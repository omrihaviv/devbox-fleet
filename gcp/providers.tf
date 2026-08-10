# Admin ADC (gcloud auth application-default login) authenticates this root.
# The project pin is the fail-closed guard: resources are created only in
# var.gcp_project_id, so stale ADC pointing at another project cannot stand
# up devbox infrastructure elsewhere.
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# Tailscale provider authenticates via OAuth client credentials.
# REQUIRED OAuth scopes (one credential drives BOTH resources via this provider):
#   - auth_keys  (write)  scoped to tag:devbox-key-minter → tailscale_tailnet_key.devbox
#   - policy_file (write)                                 → tailscale_acl.devbox
#
# Tailscale OAuth clients do NOT support tag wildcards. Authorization works
# via the delegating-tag pattern: the OAuth client owns tag:devbox-key-minter,
# and tailscale-acl.tf declares tag:devbox-key-minter as an owner of every
# per-machine tag. See docs/admin-runbook.md for OAuth client setup.
#
# Fail-closed tailnet guard: the tailnet pin ensures wrong-tailnet credentials
# (personal/staging org) cannot silently authenticate and overwrite that
# tailnet's ACL or mint usable keys there.
provider "tailscale" {
  oauth_client_id     = var.tailscale_oauth_client_id
  oauth_client_secret = var.tailscale_oauth_client_secret
  tailnet             = var.tailscale_tailnet
}
