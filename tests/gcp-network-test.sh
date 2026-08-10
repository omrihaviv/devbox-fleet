#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETWORK="$ROOT_DIR/gcp/network.tf"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { rg -q --fixed-strings "$1" "$NETWORK" || fail "expected gcp/network.tf to contain: $1"; }

[ -f "$NETWORK" ] || fail "gcp/network.tf missing"

# Custom-mode VPC (implicit deny ingress).
assert_contains 'auto_create_subnetworks = false'

# WireGuard in from anywhere; SSH ONLY from the IAP range.
assert_contains '"41641"'
assert_contains '35.235.240.0/20'

# Port 22 must never pair with a public source range. The SSH port lives in the
# allow{} block while source_ranges sits at resource level, so a naive same-line
# regex can't catch a regression. Instead, extract the whole iap_ssh firewall
# resource (header through its top-level closing brace) and assert on it directly.
IAP_BLOCK="$(awk '/^resource "google_compute_firewall" "iap_ssh"/{f=1} f{print} f && /^}/{exit}' "$NETWORK")"
[ -n "$IAP_BLOCK" ] || fail "could not locate the iap_ssh firewall resource in gcp/network.tf"
printf '%s\n' "$IAP_BLOCK" | rg -q --fixed-strings 'source_ranges = ["35.235.240.0/20"]' \
  || fail "iap_ssh must pin source_ranges to the IAP range [35.235.240.0/20]"
if printf '%s\n' "$IAP_BLOCK" | rg -q --fixed-strings '0.0.0.0/0'; then
  fail "iap_ssh (port 22) must only be reachable from the IAP range, never 0.0.0.0/0"
fi

echo "PASS: gcp-network-test"
