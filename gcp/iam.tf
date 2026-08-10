# The dedicated project IS the security boundary: devbox-admins get
# roles/owner via the bootstrap runbook (NOT Terraform — Terraform runs as a
# member of that group; managing the grant that authorizes itself risks a
# lockout on a bad apply). Terraform manages the EXPLICIT breakglass grants
# so they survive a later narrowing of owner, plus the instance SA.

# Instance identity for every devbox. Grants are telemetry + runtime-bundle
# reads ONLY (objectViewer is bucket-scoped in runtime.tf) — a compromised
# box cannot see or touch the fleet.
resource "google_service_account" "devbox_instance" {
  account_id   = "devbox-instance"
  display_name = "Devbox instance identity (telemetry + runtime bundle reads)"
}

resource "google_project_iam_member" "instance_metric_writer" {
  project = var.gcp_project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.devbox_instance.email}"
}

resource "google_project_iam_member" "instance_log_writer" {
  project = var.gcp_project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.devbox_instance.email}"
}

# ----- Breakglass grant set — explicit, survives owner narrowing -----

resource "google_project_iam_member" "admins_os_admin_login" {
  project = var.gcp_project_id
  role    = "roles/compute.osAdminLogin"
  member  = "group:${var.devbox_admins_group}"
}

resource "google_project_iam_member" "admins_iap_tunnel" {
  project = var.gcp_project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "group:${var.devbox_admins_group}"
}

# OS Login SSH to a VM with an attached SA requires actAs on that SA.
# Without this, `gcloud compute ssh --tunnel-through-iap` fails for
# non-owner admins — the "survives narrowing owner" claim depends on it.
resource "google_service_account_iam_member" "admins_actas_instance_sa" {
  service_account_id = google_service_account.devbox_instance.name
  role               = "roles/iam.serviceAccountUser"
  member             = "group:${var.devbox_admins_group}"
}

# OS Login project-wide: IAM (not metadata SSH keys) governs the breakglass
# path; per-instance opt-outs are impossible by omission.
resource "google_compute_project_metadata_item" "enable_oslogin" {
  key   = "enable-oslogin"
  value = "TRUE"
}
