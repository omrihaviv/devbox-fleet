#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$ROOT_DIR/gcp/templates/startup-script.sh.tftpl"
COMPUTE="$ROOT_DIR/gcp/compute.tf"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { rg -q --fixed-strings -- "$2" "$1" || fail "expected $1 to contain: $2"; }
assert_not_contains() { if rg -q --fixed-strings -- "$2" "$1"; then fail "expected $1 to NOT contain: $2"; fi; }

[ -f "$TPL" ] || fail "gcp/templates/startup-script.sh.tftpl missing"
[ -f "$COMPUTE" ] || fail "gcp/compute.tf missing"

line_of() { rg -n --fixed-strings "$1" "$TPL" | head -1 | cut -d: -f1; }

# Deterministic GCE device path — the Nitro by-id hack is dead.
assert_contains "$TPL" '/dev/disk/by-id/google-data'
assert_not_contains "$TPL" 'nvme-Amazon_Elastic_Block_Store'

# No AWS CLI in the boot path (design global constraint).
assert_not_contains "$TPL" 'aws s3'
assert_not_contains "$TPL" 'awscli'

# Ordering invariants:
# storage assertions (every boot) BEFORE the marker guard BEFORE tailscale
# BEFORE converge fetch; marker write is the LAST step.
mount_line="$(line_of 'mountpoint -q')"
marker_guard_line="$(line_of '/var/lib/devbox-bootstrap/complete ]')"
tailscale_line="$(line_of 'tailscale up')"
converge_line="$(line_of 'devbox-converge')"
marker_write_line="$(rg -n --fixed-strings 'devbox-bootstrap/complete' "$TPL" | tail -1 | cut -d: -f1)"

[ -n "$mount_line" ] && [ -n "$marker_guard_line" ] && [ -n "$tailscale_line" ] \
  && [ -n "$converge_line" ] && [ -n "$marker_write_line" ] || fail "expected ordering anchors missing"
[ "$mount_line" -lt "$marker_guard_line" ] || fail "storage assertions must run EVERY boot — before the marker guard"
[ "$marker_guard_line" -lt "$tailscale_line" ] || fail "marker guard must precede one-time tailscale auth"
[ "$tailscale_line" -lt "$converge_line" ] || fail "tailscale must come up before converge fetch"
[ "$converge_line" -lt "$marker_write_line" ] || fail "marker write must be the final step"
assert_contains "$TPL" '--operator=dev'

# VS Code is new-GCP-root-only. Arm its retry marker before the first manifest
# fetch, because that fetch can fail while bootstrap still reaches completion.
runtime_bucket_line="$(line_of '/etc/devbox/runtime-bucket')"
vscode_marker_line="$(line_of 'touch /var/lib/devbox-runtime/vscode-required' || true)"
converge_fetch_line="$(line_of 'converge_bootstrap_ok=false')"
if [ -z "$runtime_bucket_line" ] || [ -z "$vscode_marker_line" ] || [ -z "$converge_fetch_line" ]; then
  fail "expected VS Code bootstrap anchors missing"
fi
[ "$runtime_bucket_line" -lt "$vscode_marker_line" ] \
  || fail "VS Code retry marker must follow runtime-bucket setup"
[ "$vscode_marker_line" -lt "$converge_fetch_line" ] \
  || fail "VS Code retry marker must precede the initial converge fetch"

# systemd-level mount enforcement for stateful daemons.
assert_contains "$TPL" 'RequiresMountsFor=/data /home /var/lib/docker /var/lib/containerd /var/lib/tailscale'

# Converge timer: 8h cadence, persistent, randomized.
assert_contains "$TPL" 'OnCalendar=*-*-* 00,08,16:00:00'
assert_contains "$TPL" 'RandomizedDelaySec=3600'
assert_contains "$TPL" 'Persistent=true'

# compute.tf invariants.
assert_contains "$COMPUTE" 'replace_triggered_by = [random_uuid.devbox_generation[each.key]]'
assert_contains "$COMPUTE" 'attached_disk,'
assert_contains "$COMPUTE" 'boot_disk[0].initialize_params[0].size,'
assert_contains "$COMPUTE" 'device_name = "data"'
assert_contains "$COMPUTE" 'devbox-swap-gib'
assert_contains "$COMPUTE" 'size  = each.value.root_disk_gb'
assert_contains "$COMPUTE" '<= 204800'

# The repos list is org-specific and gitignored: Terraform must plan without it.
assert_contains "$COMPUTE" 'fileexists("${path.module}/../scripts/devbox-repos.default")'
[ ! -f "$ROOT_DIR/scripts/devbox-repos.default" ] || {
  rg -q 'devbox-repos\.default' "$ROOT_DIR/.gitignore" || fail "devbox-repos.default present but not gitignored"
}
[ -f "$ROOT_DIR/scripts/devbox-repos.example" ] || fail "scripts/devbox-repos.example missing"

echo "PASS: gcp-startup-script-test"
