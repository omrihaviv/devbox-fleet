# Consumed by aws-federation/ as var.sa_unique_id: apply this root first, then
# aws-federation/. The trust policy pins this NUMERIC ID, never the email —
# emails are reusable after SA deletion.
output "devbox_instance_sa_unique_id" {
  description = "Numeric unique ID of the devbox instance SA, for the aws-federation trust policy."
  value       = google_service_account.devbox_instance.unique_id
}

output "devbox_instance_sa_email" {
  description = "Email of the devbox instance SA."
  value       = google_service_account.devbox_instance.email
}

output "runtime_bucket" {
  description = "GCS runtime bucket name (consumed by promote-runtime.sh and the boot template)."
  value       = google_storage_bucket.devbox_runtime.name
}

output "runtime_manifest_sha256" {
  description = "Sha of the candidate manifest uploaded by this apply. Canary with `scripts/gcp/sync-converge.sh <machine> --manifest-sha <this>`, then promote with `scripts/gcp/promote-runtime.sh <this>`."
  value       = local.runtime_manifest_sha256
}

# Renders while manage_tailscale_acl = false, when it is a machine-free
# skeleton. For the exact gate-open policy, inspect this output in the saved
# first-machine plan before applying it (the resource replaces the whole
# tailnet policy).
output "devbox_acl_json" {
  description = "Rendered ACL document: a skeleton while the ownership gate is closed; inspect its planned value with pending machines for the exact gate-open policy."
  value       = local.devbox_acl_json
}

output "devbox_hostnames" {
  description = "Machine key → tailnet hostname (<key>-devbox). A dev reaches their box as ssh dev@<key>-devbox."
  value       = { for k, _ in local.machines : k => "${k}-devbox" }
}

output "devbox_instance_names" {
  description = "Machine key → GCE instance name (for gcloud breakglass: gcloud compute ssh <name> --tunnel-through-iap)."
  value       = { for k, _ in local.machines : k => google_compute_instance.devbox[k].name }
}

output "devbox_data_disk_names" {
  description = "Machine key → data disk name (for the offboarding snapshot runbook)."
  value       = { for k, _ in local.machines : k => google_compute_disk.data[k].name }
}
