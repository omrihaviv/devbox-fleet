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

# Exercise real package reconciliation with fake system commands. The version
# marker must never substitute for dpkg's installed version or package status.
mkdir -p "$work/bin" "$work/apt"
touch "$work/apt/google-cloud-ops-agent.list"
cat > "$work/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ -f "$OBS_TEST_WORK/package-version" ] || exit 1
if [ "$#" -eq 2 ]; then exit 0; fi
printf '%s %s\n' "$(cat "$OBS_TEST_WORK/package-status")" "$(cat "$OBS_TEST_WORK/package-version")"
EOF
cat > "$work/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$OBS_TEST_WORK/apt-calls"
if [ "$1" = install ]; then
  [ "${OBS_TEST_INSTALL_FAIL:-0}" != 1 ] || exit 42
  if [ "${OBS_TEST_INSTALL_NOOP:-0}" != 1 ]; then
    printf '%s\n' "${OBS_TEST_INSTALL_VERSION:-2.70.0~ubuntu24.04}" > "$OBS_TEST_WORK/package-version"
    printf 'installed\n' > "$OBS_TEST_WORK/package-status"
  fi
fi
EOF
# Package tests use a fixture repo and must never download a signing key.
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo 'unexpected repository bootstrap' >&2
exit 1
EOF
cat > "$work/bin/gpg" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OBS_TEST_WORK/systemctl-calls"
EOF
chmod +x "$work/bin/"*

run_package_obs() {
  PATH="$work/bin:$PATH" \
  OBS_TEST_WORK="$work" \
  DEVBOX_OPS_AGENT_VERSION="2.70.0" \
  DEVBOX_OPS_AGENT_CONFIG="$work/config.yaml" \
  DEVBOX_RUNTIME_STATE_DIR="$work/state" \
  DEVBOX_APT_SOURCE_DIR="$work/apt" \
  DEVBOX_SKIP_ROOT_CHECK=1 \
  bash "$OBS"
}

reset_package_fixture() {
  printf '%s\n' "$1" > "$work/package-version"
  printf '%s\n' "${2:-installed}" > "$work/package-status"
  printf '2.70.0\n' > "$work/state/ops-agent.version"
  : > "$work/apt-calls"
  : > "$work/systemctl-calls"
}

# Reproduce a marker that claims convergence after an out-of-band upgrade.
reset_package_fixture '2.71.0~ubuntu24.04'
run_package_obs >/dev/null
rg -q --fixed-strings 'install -y --allow-downgrades google-cloud-ops-agent=2.70.0*' "$work/apt-calls" \
  || fail "a matching marker must not hide installed package drift"
[ "$(cat "$work/package-version")" = '2.70.0~ubuntu24.04' ] \
  || fail "drifted package must be reconciled"
rg -q --fixed-strings 'restart google-cloud-ops-agent' "$work/systemctl-calls" \
  || fail "a changed package must restart the agent"

# Missing or stale bookkeeping is repaired without reinstalling a correct
# package or restarting its service. Exact versions and distro suffixes work.
for installed_version in '2.70.0' '2.70.0~ubuntu24.04' '2.70.0-1' '2.70.0+build1'; do
  reset_package_fixture "$installed_version"
  rm "$work/state/ops-agent.version"
  run_package_obs >/dev/null
  [ ! -s "$work/apt-calls" ] || fail "a missing marker must not reinstall a correct package"
  [ ! -s "$work/systemctl-calls" ] || fail "marker repair must not restart the agent"
  [ "$(cat "$work/state/ops-agent.version")" = '2.70.0' ] || fail "marker must be repaired"
done
reset_package_fixture '2.70.0~ubuntu24.04'
printf '2.55.0\n' > "$work/state/ops-agent.version"
run_package_obs >/dev/null
[ ! -s "$work/apt-calls" ] || fail "a stale marker must not reinstall a correct package"
[ ! -s "$work/systemctl-calls" ] || fail "a stale marker must not restart the agent"
[ "$(cat "$work/state/ops-agent.version")" = '2.70.0' ] || fail "stale marker must be repaired"

# Removed packages can remain in dpkg's database, and version-prefix matches
# must not accept another release such as 2.70.01.
reset_package_fixture '2.70.0~ubuntu24.04' 'config-files'
run_package_obs >/dev/null
[ -s "$work/apt-calls" ] || fail "a removed package must be reinstalled"
reset_package_fixture '2.70.01~ubuntu24.04'
run_package_obs >/dev/null
[ -s "$work/apt-calls" ] || fail "the version match must respect release boundaries"
reset_package_fixture '2.70.0~ubuntu24.04'
rm "$work/package-version"
run_package_obs >/dev/null
[ -s "$work/apt-calls" ] || fail "a missing package must be installed"

# Apt success alone cannot justify a success marker. Failures leave the
# marker absent and do not report a successful package/service reconciliation.
for failure_mode in OBS_TEST_INSTALL_FAIL OBS_TEST_INSTALL_NOOP; do
  reset_package_fixture '2.55.0~ubuntu24.04'
  if (export "$failure_mode=1"; run_package_obs) >"$work/failure.log" 2>&1; then
    fail "$failure_mode must fail package reconciliation"
  fi
  [ ! -e "$work/state/ops-agent.version" ] || fail "a failed repair must invalidate the version marker"
  [ ! -s "$work/systemctl-calls" ] || fail "a failed repair must not claim a successful restart"
done

echo "PASS: gcp-observability-test"
