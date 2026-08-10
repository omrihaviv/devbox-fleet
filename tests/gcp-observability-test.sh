#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS="$repo_root/scripts/gcp/devbox-observability"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$OBS" ] || fail "scripts/gcp/devbox-observability missing or not executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/state"

run_obs() {
  DEVBOX_OPS_AGENT_VERSION="2.55.0" \
  DEVBOX_OPS_AGENT_CONFIG="$work/config.yaml" \
  DEVBOX_RUNTIME_STATE_DIR="$work/state" \
  DEVBOX_SKIP_APT=1 \
  DEVBOX_SKIP_SYSTEMCTL=1 \
  DEVBOX_SKIP_ROOT_CHECK=1 \
  bash "$OBS"
}

out1="$(run_obs)"
[ -f "$work/config.yaml" ] || fail "config.yaml not written"
grep -q 'hostmetrics' "$work/config.yaml" || fail "hostmetrics receiver missing"
if rg -q --fixed-strings 'type: processes' "$work/config.yaml"; then
  fail "a 'processes' metrics receiver type does not exist in the Ops Agent — it fails config validation (per-process metrics ship via hostmetrics)"
fi
echo "$out1" | grep -q 'restart-needed' || fail "first run must mark restart-needed"

# Second run: change-detection — no restart marker.
out2="$(run_obs)"
echo "$out2" | grep -q 'already converged' || fail "second run must detect no-op"
if echo "$out2" | grep -q 'restart-needed'; then fail "no-op run must not restart the agent"; fi

# Missing version pin → fatal.
if DEVBOX_OPS_AGENT_CONFIG="$work/config.yaml" DEVBOX_RUNTIME_STATE_DIR="$work/state" \
   DEVBOX_SKIP_APT=1 DEVBOX_SKIP_SYSTEMCTL=1 DEVBOX_SKIP_ROOT_CHECK=1 bash "$OBS" 2>/dev/null; then
  fail "must fail when DEVBOX_OPS_AGENT_VERSION is unset"
fi

echo "PASS: gcp-observability-test"
