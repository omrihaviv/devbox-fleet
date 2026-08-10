#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISKS="$ROOT_DIR/gcp/disks.tf"
BACKUP="$ROOT_DIR/gcp/backup.tf"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { rg -q --fixed-strings "$2" "$1" || fail "expected $1 to contain: $2"; }

[ -f "$DISKS" ] || fail "gcp/disks.tf missing"
[ -f "$BACKUP" ] || fail "gcp/backup.tf missing"

# Data disks survive accidental destroys and instance replacement.
assert_contains "$DISKS" 'prevent_destroy = true'
assert_contains "$DISKS" 'devbox-backup'

# Daily schedule, 30-day retention, snapshots outlive disk deletion.
assert_contains "$BACKUP" 'max_retention_days    = 30'
assert_contains "$BACKUP" 'KEEP_AUTO_SNAPSHOTS'
assert_contains "$BACKUP" 'google_compute_disk_resource_policy_attachment'

echo "PASS: gcp-disks-backup-test"
