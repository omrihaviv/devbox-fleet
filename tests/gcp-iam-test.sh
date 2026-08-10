#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IAM="$ROOT_DIR/gcp/iam.tf"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { rg -q --fixed-strings "$1" "$IAM" || fail "expected gcp/iam.tf to contain: $1"; }

[ -f "$IAM" ] || fail "gcp/iam.tf missing"

# The complete three-grant breakglass set. serviceAccountUser on the instance
# SA is load-bearing: OS Login SSH to an SA-attached VM requires actAs; without
# it, narrowing owner breaks the emergency path.
assert_contains 'roles/compute.osAdminLogin'
assert_contains 'roles/iap.tunnelResourceAccessor'
assert_contains 'roles/iam.serviceAccountUser'
assert_contains 'google_service_account_iam_member'

# Instance SA project grants: telemetry only, no compute permissions.
assert_contains 'roles/monitoring.metricWriter'
assert_contains 'roles/logging.logWriter'
if rg -q '"roles/compute.admin"|"roles/editor"|"roles/owner"' "$IAM"; then
  fail "instance SA / group grants must not include compute.admin, editor, or owner (owner is granted in the bootstrap runbook, not Terraform)"
fi

# OS Login enabled project-wide.
assert_contains 'enable-oslogin'

# SA unique ID exported for aws-federation/.
rg -q --fixed-strings 'devbox_instance_sa_unique_id' "$ROOT_DIR/gcp/outputs.tf" \
  || fail "expected gcp/outputs.tf to output devbox_instance_sa_unique_id"

echo "PASS: gcp-iam-test"
