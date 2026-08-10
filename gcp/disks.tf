resource "google_compute_disk" "data" {
  for_each = local.machines

  name = "devbox-data-${each.key}"
  zone = each.value.zone
  type = "pd-balanced"
  size = each.value.data_disk_gb

  # Labels: devbox=true is the broad inventory marker; devbox-backup=true is
  # the NARROW selector documenting which disks carry the snapshot schedule
  # (boot disks are disposable and must never be snapshotted).
  labels = {
    devbox          = "true"
    "devbox-backup" = "true"
    dev             = each.key
    owner           = each.value.owner
  }

  # prevent_destroy guards against `terraform destroy` of ALL data disks.
  # It does NOT support per-key carve-outs — OFFBOARDING therefore goes:
  # stop instance → manual snapshot → verified test-restore → `terraform
  # state rm google_compute_disk.data[\"<key>\"]` (+ the attachment) →
  # gcloud delete → drop tfvars entry → apply. See docs/admin-runbook.md
  # "Offboarding". Do not relax this lifecycle for a single machine.
  #
  # Grow-only: raising size resizes in place (then `sudo resize2fs
  # /dev/disk/by-id/google-data` per the runbook); GCE rejects shrinks.
  lifecycle {
    prevent_destroy = true
  }
}
