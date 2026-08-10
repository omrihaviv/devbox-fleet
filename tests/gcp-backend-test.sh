#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="$ROOT_DIR/gcp/versions.tf"
EX="$ROOT_DIR/gcp/backend.hcl.example"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { rg -q --fixed-strings -- "$2" "$1" || fail "expected $1 to contain: $2"; }
assert_not_contains() { if rg -q --fixed-strings -- "$2" "$1"; then fail "expected $1 to NOT contain: $2"; fi; }

# Empty partial backend — org config arrives via -backend-config=backend.hcl.
# Asserted structurally, not against the old bucket's literal name: this file
# ships in the public export, so naming it here would trip release/leak-scan.sh,
# and 'bucket =' catches ANY hardcoded bucket rather than just the one we removed.
assert_contains "$V" 'backend "gcs" {}'
assert_not_contains "$V" 'bucket ='

# The example must carry BOTH keys the live backend uses — omitting prefix
# would misdirect state on a fresh clone.
[ -f "$EX" ] || fail "gcp/backend.hcl.example missing"
assert_contains "$EX" 'bucket = "'
assert_contains "$EX" 'prefix = "gcp"'

# The real backend.hcl must be ignored.
rg -q 'backend\.hcl$' "$ROOT_DIR/.gitignore" || fail ".gitignore must cover backend.hcl"

# Saved plans can contain sensitive variable values (including the Tailscale
# OAuth secret), so both the conventional bare name and *.tfplan files must be
# ignored in every Terraform root.
git -C "$ROOT_DIR" check-ignore -q gcp/tfplan \
  || fail ".gitignore must cover the conventional gcp/tfplan path"
git -C "$ROOT_DIR" check-ignore -q gcp/saved.tfplan \
  || fail ".gitignore must cover *.tfplan"
echo "PASS gcp-backend-test"
