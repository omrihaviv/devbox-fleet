#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON="$ROOT_DIR/gcp/monitoring.tf"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { rg -q --fixed-strings "$1" "$MON" || fail "expected gcp/monitoring.tf to contain: $1"; }
assert_not_contains() { ! rg -q --fixed-strings "$1" "$MON" || fail "expected gcp/monitoring.tf not to contain: $1"; }

[ -f "$MON" ] || fail "gcp/monitoring.tf missing"

# The heartbeat token from scripts/gcp/devbox-converge. The Ops Agent syslog
# pipeline may land it in either textPayload or jsonPayload.message, so the
# metric filter must match BOTH fields (keying on textPayload alone silently
# never increments the metric and the absence alert never arms).
assert_contains 'textPayload:\"devbox-converge-success\"'
assert_contains 'jsonPayload.message:\"devbox-converge-success\"'

# 23h absence window — Cloud Monitoring caps at 23.5h (84600s); 26h+ is
# UNCONFIGURABLE (design review finding). 82800s = 23h.
assert_contains '82800s'
assert_contains 'condition_absent'

# Preserve the native gce_instance resource identity. Reducing by instance_id
# alone discards the zone and can make a deleted instance look stale.
assert_not_contains 'cross_series_reducer'
assert_not_contains 'group_by_fields'

# Only current Terraform-managed instances are eligible. Historical metric
# series from replaced/deleted instances must not satisfy the alert filter.
assert_contains 'for instance in values(google_compute_instance.devbox)'
assert_contains 'resource.label.instance_id ='
assert_contains '${local.converge_instance_filter}'
assert_contains 'var.devbox_alert_email == "" || length(local.machines) == 0 ? 0 : 1'

# Empty alert email disables channel + policy.
assert_contains 'var.devbox_alert_email == "" ? 0 : 1'

# Fleet dashboard: the per-process + host metrics investigation surface.
assert_contains 'google_monitoring_dashboard'
assert_contains 'agent.googleapis.com/memory/percent_used'
assert_contains 'agent.googleapis.com/swap/percent_used'
assert_contains 'compute.googleapis.com/instance/cpu/utilization'

# Dashboard JSON must stay byte-equal to what the Monitoring API returns, or
# every plan shows a permanent no-op diff on the dashboard. Two rules:
#   1. Declare the defaults the API fills in on write (plotType, targetAxis).
#   2. Never emit zero-valued tile positions — the API omits them on read, so
#      an explicit `xPos = 0` can never match. Hence the `if v != 0` filter.
assert_contains 'plotType   = "LINE"'
assert_contains 'targetAxis = "Y1"'
assert_contains 'if v != 0'
assert_not_contains 'xPos   = (idx % 2) * 6'

echo "PASS: gcp-monitoring-test"
