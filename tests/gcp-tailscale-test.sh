#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACL="$ROOT_DIR/gcp/tailscale-acl.tf"
KEYS="$ROOT_DIR/gcp/tailscale.tf"
RUNBOOK="$ROOT_DIR/docs/admin-runbook.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { rg -q --fixed-strings "$2" "$1" || fail "expected $1 to contain: $2"; }

[ -f "$ACL" ] || fail "gcp/tailscale-acl.tf missing"
[ -f "$KEYS" ] || fail "gcp/tailscale.tf missing"
[ -f "$RUNBOOK" ] || fail "docs/admin-runbook.md missing"

# The ownership gate: resource is count-gated.
assert_contains "$ACL" 'count = var.manage_tailscale_acl ? 1 : 0'
assert_contains "$ACL" 'overwrite_existing_content = true'

# ACL constructs render over the UNION (GCP machines + var.frozen_aws_machines).
assert_contains "$ACL" 'local.acl_machines'

# Required ACL constructs (see the Structure note in tailscale-acl.tf).
assert_contains "$ACL" 'tag:devbox-key-minter'
assert_contains "$ACL" 'group:devbox-admins'
assert_contains "$ACL" 'autogroup:member'
assert_contains "$ACL" ':3000,3005'
assert_contains "$ACL" 'funnel'

# Keys: per GCP machine only, lockstep-replaced.
assert_contains "$KEYS" 'reusable      = true'
assert_contains "$KEYS" 'ephemeral     = false'
assert_contains "$KEYS" 'expiry        = 86400'
assert_contains "$KEYS" 'preauthorized = true'
assert_contains "$KEYS" 'replace_triggered_by'
assert_contains "$KEYS" 'for_each = local.machines'

# Expiry rotates the key WITHOUT churning instance metadata: a key that goes
# invalid on its own must never be recreated, or every plan >24h after the
# last apply shows a no-op startup-script update on every machine. Rebuilds
# still mint fresh keys via replace_triggered_by (asserted above).
assert_contains "$KEYS" 'recreate_if_invalid = "never"'

# The first ACL takeover must fail closed if Terraform omits the planned
# output or emits malformed JSON; a plain multi-stage jq pipeline can mask an
# earlier failure unless pipefail and jq's exit-status mode are both enabled.
assert_contains "$RUNBOOK" 'set -euo pipefail'
assert_contains "$RUNBOOK" 'select(type == "string" and length > 0)'
assert_contains "$RUNBOOK" '| jq -e .'

echo "PASS: gcp-tailscale-test"
