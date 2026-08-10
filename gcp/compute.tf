# Per-machine generation token: any keeper change forces a LOCKSTEP rebuild
# of instance + Tailscale auth key (replace_triggered_by on both). Keepers
# are exactly: explicit generation knob, pinned image, bootstrap template
# hash, and the two rebuild-bound chrome wrappers (root-owned security
# artifacts — deliberately NOT day-2).
#
# NOT keepers (day-2, no rebuild): converge bundle contents (GCS manifest),
# swap_gib (instance metadata → next converge), data_disk_gb (in-place
# resize), devbox-onboard / devbox-repos.default (sync-onboard.sh).
resource "random_uuid" "devbox_generation" {
  for_each = local.machines

  keepers = {
    generation           = each.value.generation
    image                = var.ubuntu_2404_image
    bootstrap_version    = filesha256("${path.module}/templates/startup-script.sh.tftpl")
    wrapper_hash         = filesha256("${path.module}/../scripts/chrome-devtools-mcp-wrapper.sh")
    steered_wrapper_hash = filesha256("${path.module}/../scripts/chrome-devtools-mcp-steered-wrapper.sh")
  }
}

locals {
  # Strip comments/blank lines from embedded scripts (shebang survives) —
  # keeps the rendered bootstrap well under the 200 KB precondition below.
  embedded_script_content = {
    for name, path in {
      devbox_onboard  = "${path.module}/../scripts/devbox-onboard"
      chrome_wrapper  = "${path.module}/../scripts/chrome-devtools-mcp-wrapper.sh"
      steered_wrapper = "${path.module}/../scripts/chrome-devtools-mcp-steered-wrapper.sh"
      } : name => join("\n", [
        for line in split("\n", file(path)) : line
        if trimspace(line) != "" && (!startswith(trimspace(line), "#") || startswith(trimspace(line), "#!"))
    ])
  }

  startup_script = {
    for k, m in local.machines : k => templatefile("${path.module}/templates/startup-script.sh.tftpl", {
      dev_name                = k
      generation              = random_uuid.devbox_generation[k].result
      ts_auth_key             = tailscale_tailnet_key.devbox[k].key
      tailscale_version       = var.toolchain.tailscale_version
      runtime_bucket          = google_storage_bucket.devbox_runtime.name
      devbox_onboard_content  = local.embedded_script_content.devbox_onboard
      devbox_repos_default    = fileexists("${path.module}/../scripts/devbox-repos.default") ? file("${path.module}/../scripts/devbox-repos.default") : ""
      chrome_wrapper_content  = local.embedded_script_content.chrome_wrapper
      steered_wrapper_content = local.embedded_script_content.steered_wrapper
    })
  }
}

resource "google_compute_instance" "devbox" {
  for_each = local.machines

  name         = "${each.key}-devbox"
  machine_type = each.value.machine_type
  zone         = each.value.zone

  # Firewall targeting: both ingress rules key off this tag.
  tags = ["devbox"]

  boot_disk {
    auto_delete = true
    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/${var.ubuntu_2404_image}"
      size  = each.value.root_disk_gb
      type  = "pd-balanced"
      labels = {
        devbox = "true"
        dev    = each.key
        owner  = each.value.owner
        role   = "root"
      }
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.devbox.id
    # Ephemeral external IP: egress + direct WireGuard — chosen over Cloud NAT
    # on cost; the firewall admits only UDP 41641 + IAP.
    access_config {}
  }

  service_account {
    email  = google_service_account.devbox_instance.email
    scopes = ["cloud-platform"] # authz is IAM-limited: telemetry + bucket read only
  }

  metadata = {
    startup-script = local.startup_script[each.key]
    # Per-machine config channel: changing swap_gib in tfvars is an IN-PLACE
    # metadata update, applied by devbox-memory-hotfix at the next converge —
    # never a rebuild.
    devbox-swap-gib = tostring(each.value.swap_gib)
  }

  labels = {
    devbox = "true"
    dev    = each.key
    owner  = each.value.owner
  }

  # machine_type changes stop+update in place instead of failing the apply.
  allow_stopping_for_update = true

  lifecycle {
    # google_compute_attached_disk manages the data-disk attachment; without
    # the first ignore the instance would fight it on every plan. Root-disk
    # size is creation-only: GCE supports online growth, but provider 6.50
    # marks initialize_params.size ForceNew. Ignore it after creation so a
    # manual grow cannot trigger an unsafe instance-only replacement.
    ignore_changes = [
      attached_disk,
      boot_disk[0].initialize_params[0].size,
    ]

    # Any generation-keeper change rebuilds instance + auth key in lockstep.
    replace_triggered_by = [random_uuid.devbox_generation[each.key]]

    # 200 KB cap on the rendered bootstrap (GCE metadata value limit is
    # 256 KB) — cheap insurance against unbounded embedded-script growth.
    precondition {
      condition     = length(local.startup_script[each.key]) <= 204800
      error_message = "Rendered startup script for '${each.key}' exceeds 200 KB. Trim embedded scripts or move content into the converge bundle."
    }
  }
}

# Separate attachment resource: instance replacement recreates the
# attachment but NEVER touches google_compute_disk.data (prevent_destroy).
# device_name=data yields the deterministic guest path
# /dev/disk/by-id/google-data on every machine type.
resource "google_compute_attached_disk" "data" {
  for_each = local.machines

  instance    = google_compute_instance.devbox[each.key].id
  disk        = google_compute_disk.data[each.key].id
  device_name = "data"
}
