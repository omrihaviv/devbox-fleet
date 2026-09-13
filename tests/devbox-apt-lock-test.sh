#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Exercise the production refresh function with APT's actual error shapes.
# The external command is faked so this never touches host package state.
sed -n '/^apt_update_if_needed()/,/^}/p' "$repo_root/scripts/devbox-toolchain" > "$work/refresh.sh"
cat > "$work/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=$(cat "$APT_TEST_DIR/count")
echo $((count + 1)) > "$APT_TEST_DIR/count"
case "$APT_TEST_CASE" in
  clears)
    if [ "$count" -ge 2 ]; then exit 0; fi
    ;;
  held) ;;
  permission)
    echo 'E: Could not open lock file /var/lib/apt/lists/lock - open (13: Permission denied)' >&2
    exit 100
    ;;
  repository)
    echo 'E: The repository does not have a Release file.' >&2
    exit 100
    ;;
  other-status) exit 42 ;;
  warning)
    echo 'W: An unrelated warning from APT' >&2
    exit 0
    ;;
  mixed|mixed-large) echo 'E: The repository does not have a Release file.' >&2 ;;
esac
echo 'E: Could not get lock /var/lib/apt/lists/lock. It is held by process 1234 (apt-get)' >&2
echo 'N: Be aware that removing the lock file is not a solution and may break your system.' >&2
echo 'E: Unable to lock directory /var/lib/apt/lists/' >&2
if [ "$APT_TEST_CASE" = mixed-large ]; then
  # Exceed a pipe buffer: error classification must not mistake SIGPIPE for
  # the absence of a repository error when pipefail is enabled.
  for ((i = 0; i < 10000; i++)); do
    echo 'E: Unable to lock directory /var/lib/apt/lists/' >&2
  done
fi
exit 100
EOF
chmod +x "$work/apt-get"

run_refresh() {
  local scenario="$1"
  mkdir -p "$work/$scenario"
  echo 0 > "$work/$scenario/count"
  APT_TEST_DIR="$work/$scenario" APT_TEST_CASE="$scenario" \
    bash -c '
      set -euo pipefail
      source "$1/refresh.sh"
      APT_GET=("$1/apt-get" -o DPkg::Lock::Timeout=300)
      apt_updated=false
      apt_needs_update=true
      # Advance the shell clock instead of waiting five real minutes.
      sleep() { SECONDS=$((SECONDS + 150)); }
      set +e
      apt_update_if_needed
      rc=$?
      set -e
      printf "%s %s\n" "$apt_updated" "$apt_needs_update" > "$APT_TEST_DIR/state"
      if [ "$rc" = 0 ]; then apt_update_if_needed; fi
      exit "$rc"
    ' _ "$work" > "$work/$scenario/out" 2>&1
}

# A temporary collision must complete within this run, then cache success.
run_refresh clears || fail "refresh failed after the competing APT lock cleared"
[ "$(cat "$work/clears/count")" = 3 ] || fail "refresh did not wait for the lock or repeated a successful refresh"
[ "$(cat "$work/clears/state")" = 'true false' ] || fail "refresh success was not recorded"

# A permanently held lock must stop waiting and leave refresh pending.
rc=0
run_refresh held || rc=$?
[ "$rc" = 100 ] || fail "held lock must fail with APT's status"
[ "$(cat "$work/held/count")" -le 3 ] || fail "held lock exceeded its wait budget"
[ "$(cat "$work/held/state")" = 'false true' ] || fail "held lock was recorded as a successful refresh"

# Real package errors, permission failures and mixed errors must fail at once.
for scenario in permission repository mixed mixed-large other-status; do
  rc=0
  run_refresh "$scenario" || rc=$?
  expected=100
  [ "$scenario" != other-status ] || expected=42
  [ "$rc" = "$expected" ] || fail "$scenario error status was lost"
  [ "$(cat "$work/$scenario/count")" = 1 ] || fail "$scenario error was retried"
  [ "$(cat "$work/$scenario/state")" = 'false true' ] || fail "$scenario failure was recorded as success"
done
rg -qF 'Permission denied' "$work/permission/out" || fail "APT diagnostics were hidden"
run_refresh warning || fail "APT warning changed a successful exit"
rg -qF 'An unrelated warning from APT' "$work/warning/out" || fail "APT warning was hidden"

echo 'PASS: devbox-apt-lock-test'
