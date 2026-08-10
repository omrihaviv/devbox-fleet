# Daily snapshots, 30-day retention. Snapshots are incremental and
# Google-encrypted. KEEP_AUTO_SNAPSHOTS makes recovery points outlive disk
# deletion (offboarding safety).
#
# ACCEPTED RISK: no vault-lock equivalent — a compromised ADMIN credential
# could delete snapshots inside the retention window. Consistent with the
# project-IAM posture; cross-project snapshot copies are the future
# hardening if ever warranted.
resource "google_compute_resource_policy" "devbox_daily" {
  name   = "devbox-daily-snapshots"
  region = var.gcp_region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "03:00" # UTC
      }
    }
    retention_policy {
      max_retention_days    = 30
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      labels = {
        devbox = "true"
      }
    }
  }
}

resource "google_compute_disk_resource_policy_attachment" "data" {
  for_each = local.machines

  name = google_compute_resource_policy.devbox_daily.name
  disk = google_compute_disk.data[each.key].name
  zone = each.value.zone
}
