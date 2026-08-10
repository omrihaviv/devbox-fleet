#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
default_avoid_regex='^(tailscaled|sshd|dockerd|containerd.*|otelopscol|google_guest_ag|google_osconfig|systemd.*|earlyoom)$'
default_earlyoom_args="-m 8,4 -s 15,8 -r 3600 --avoid $default_avoid_regex"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_log_absent() {
  local log="$1"
  local pattern="$2"

  if [ -f "$log" ] && grep -Fq "$pattern" "$log"; then
    echo "--- command log ---" >&2
    cat "$log" >&2
    fail "unexpected command log entry: $pattern"
  fi
}

assert_log_contains() {
  local log="$1"
  local pattern="$2"

  if ! [ -f "$log" ] || ! grep -Fq "$pattern" "$log"; then
    echo "--- command log ---" >&2
    cat "$log" >&2 || true
    fail "missing command log entry: $pattern"
  fi
}

assert_state_value() {
  local workdir="$1" name="$2" expected="$3" actual

  [ -f "$workdir/test-state/$name" ] \
    || fail "missing fake state value: $name"
  actual="$(cat "$workdir/test-state/$name")"
  [ "$actual" = "$expected" ] \
    || fail "fake state $name: expected '$expected', got '$actual'"
}

make_fake_bin() {
  local fake_bin="$1"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  if [ "$#" -eq 1 ]; then
    echo 0
  else
    echo "${FAKE_DEV_UID:-1000}"
  fi
else
  /usr/bin/id "$@"
fi
EOF
  cat > "$fake_bin/install" <<'EOF'
#!/usr/bin/env bash
target="${@: -1}"
if [ -n "${FAKE_EARLYOOM_DEFAULT_INSTALL_FAIL_ON_ATTEMPT:-}" ] \
  && [ "$target" = "$DEVBOX_EARLYOOM_DEFAULT" ]; then
  attempts_file="$DEVBOX_TEST_STATE_DIR/earlyoom-default-install-attempts"
  attempts=0
  if [ -f "$attempts_file" ]; then
    attempts="$(cat "$attempts_file")"
  fi
  attempts=$((attempts + 1))
  printf '%s\n' "$attempts" > "$attempts_file"
  if [ "$attempts" -eq "$FAKE_EARLYOOM_DEFAULT_INSTALL_FAIL_ON_ATTEMPT" ]; then
    exit "${FAKE_EARLYOOM_DEFAULT_INSTALL_RC:-1}"
  fi
fi
exec /usr/bin/install "$@"
EOF
  cat > "$fake_bin/df" <<'EOF'
#!/usr/bin/env bash
printf 'Avail\n%sG\n' "${FAKE_ROOT_AVAIL_G:-100}"
EOF
  cat > "$fake_bin/free" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-b" ]; then
  printf '              total        used        free\n'
  printf 'Swap:    1073741824           %s  1073741824\n' "${FAKE_SWAP_USED_BYTES:-0}"
else
  printf '              total        used        free\n'
  printf 'Swap:           1Gi          0B       1Gi\n'
fi
EOF
  cat > "$fake_bin/stat" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "%s" ]; then
  wc -c < "$3" | tr -d ' '
else
  /usr/bin/stat "$@"
fi
EOF
  cat > "$fake_bin/sysctl" <<'EOF'
#!/usr/bin/env bash
echo "sysctl $*" >> "$DEVBOX_TEST_LOG"
EOF
  cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
state_value() {
  local name="$1" fallback="$2"
  if [ -f "$DEVBOX_TEST_STATE_DIR/$name" ]; then
    cat "$DEVBOX_TEST_STATE_DIR/$name"
  else
    printf '%s\n' "$fallback"
  fi
}
write_state() {
  printf '%s\n' "$2" > "$DEVBOX_TEST_STATE_DIR/$1"
}
case "$*" in
  "cat systemd-oomd.service")
    exit 0
    ;;
  "show user.slice -p ManagedOOMMemoryPressure --value")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    state_value user-slice-pressure "${FAKE_MANAGED_OOM_MEMORY_PRESSURE:-auto}"
    ;;
  "show user.slice -p ManagedOOMMemoryPressureLimit --value")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    state_value user-slice-limit "${FAKE_MANAGED_OOM_MEMORY_PRESSURE_LIMIT:-0}"
    ;;
  "show user.slice -p ManagedOOMSwap --value")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    state_value user-slice-swap "${FAKE_MANAGED_OOM_SWAP:-kill}"
    ;;
  "show user@${FAKE_DEV_UID:-1000}.service -p ManagedOOMMemoryPressure --value")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    attempts_file="$DEVBOX_TEST_STATE_DIR/user-service-query-attempts"
    attempts=0
    if [ -f "$attempts_file" ]; then
      attempts="$(cat "$attempts_file")"
    fi
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" > "$attempts_file"
    if [ -n "${FAKE_USER_SERVICE_QUERY_FAIL_ON_ATTEMPT:-}" ] \
      && [ "$attempts" -eq "$FAKE_USER_SERVICE_QUERY_FAIL_ON_ATTEMPT" ]; then
      exit "${FAKE_USER_SERVICE_QUERY_FAIL_RC:-23}"
    fi
    if [ "${FAKE_USER_SERVICE_QUERY_RC:-0}" -ne 0 ]; then
      exit "$FAKE_USER_SERVICE_QUERY_RC"
    fi
    state_value user-service-pressure "${FAKE_USER_SERVICE_PRESSURE:-kill}"
    ;;
  "show user@.service -p ManagedOOMMemoryPressure --value")
    echo "bare template user@.service is not a valid unit" >&2
    exit 64
    ;;
  "is-active --quiet systemd-oomd")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    exit "${FAKE_OOMD_ACTIVE_RC:-0}"
    ;;
  "is-active systemd-oomd")
    echo active
    ;;
  "is-active --quiet earlyoom")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    if [ -f "$DEVBOX_TEST_STATE_DIR/earlyoom-disabled" ]; then
      exit 1
    fi
    exit "${FAKE_EARLYOOM_ACTIVE_RC:-0}"
    ;;
  "is-active --quiet user@${FAKE_DEV_UID:-1000}.service")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    exit "${FAKE_USER_SERVICE_ACTIVE_RC:-0}"
    ;;
  "is-active earlyoom")
    echo active
    ;;
  "is-enabled --quiet earlyoom")
    if [ -f "$DEVBOX_TEST_STATE_DIR/earlyoom-disabled" ]; then
      exit 1
    fi
    exit "${FAKE_EARLYOOM_ENABLED_RC:-0}"
    ;;
  "show earlyoom -p MainPID --value")
    if [ "${FAKE_EARLYOOM_MAIN_PID_QUERY_RC:-0}" -ne 0 ]; then
      exit "$FAKE_EARLYOOM_MAIN_PID_QUERY_RC"
    fi
    echo "${FAKE_EARLYOOM_MAIN_PID:-4242}"
    ;;
  "restart earlyoom")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    if [ "${FAKE_EARLYOOM_RESTART_FAIL_ONCE:-0}" = 1 ] \
      && [ ! -f "$DEVBOX_TEST_STATE_DIR/earlyoom-restart-attempted" ]; then
      touch "$DEVBOX_TEST_STATE_DIR/earlyoom-restart-attempted"
      exit 1
    fi
    exit "${FAKE_EARLYOOM_RESTART_RC:-0}"
    ;;
  "unmask earlyoom")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    if [ "${FAKE_EARLYOOM_UNMASK_FAIL_ONCE:-0}" = 1 ] \
      && [ ! -f "$DEVBOX_TEST_STATE_DIR/earlyoom-unmask-attempted" ]; then
      touch "$DEVBOX_TEST_STATE_DIR/earlyoom-unmask-attempted"
      exit 1
    fi
    rc="${FAKE_EARLYOOM_UNMASK_RC:-0}"
    if [ "$rc" -eq 0 ]; then
      rm -f "$DEVBOX_TEST_STATE_DIR/earlyoom-masked"
    fi
    exit "$rc"
    ;;
  "disable --now earlyoom")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    if [ "${FAKE_EARLYOOM_DISABLE_RC:-0}" -eq 0 ]; then
      touch "$DEVBOX_TEST_STATE_DIR/earlyoom-disabled"
    fi
    exit "${FAKE_EARLYOOM_DISABLE_RC:-0}"
    ;;
  "mask earlyoom")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    touch "$DEVBOX_TEST_STATE_DIR/earlyoom-masked"
    ;;
  "enable --now earlyoom")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    rm -f "$DEVBOX_TEST_STATE_DIR/earlyoom-disabled"
    ;;
  "enable systemd-oomd")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    ;;
  "enable --now systemd-oomd")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    exit "${FAKE_OOMD_ENABLE_NOW_RC:-0}"
    ;;
  "restart systemd-oomd")
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    exit "${FAKE_OOMD_RESTART_RC:-0}"
    ;;
  set-property\ user.slice*)
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    attempts_file="$DEVBOX_TEST_STATE_DIR/user-slice-set-property-attempts"
    attempts=0
    if [ -f "$attempts_file" ]; then
      attempts="$(cat "$attempts_file")"
    fi
    attempts=$((attempts + 1))
    printf '%s\n' "$attempts" > "$attempts_file"
    if [ -n "${FAKE_USER_SLICE_SET_PROPERTY_FAIL_ON_ATTEMPT:-}" ] \
      && [ "$attempts" -eq "$FAKE_USER_SLICE_SET_PROPERTY_FAIL_ON_ATTEMPT" ]; then
      exit "${FAKE_USER_SLICE_SET_PROPERTY_FAIL_RC:-33}"
    fi
    exit_rc="${FAKE_USER_SLICE_SET_PROPERTY_RC:-0}"
    if [ "$exit_rc" -ne 0 ]; then
      exit "$exit_rc"
    fi
    for property in "${@:3}"; do
      case "$property" in
        ManagedOOMMemoryPressure=*)
          write_state user-slice-pressure "${property#*=}"
          ;;
        ManagedOOMMemoryPressureLimit=*)
          value="${property#*=}"
          if [ -z "$value" ]; then
            echo "Failed to parse ManagedOOMMemoryPressureLimit= value:" >&2
            exit 64
          fi
          if [ "$value" = "70%" ]; then
            value=3006477107
          elif [ "$value" = "0%" ]; then
            value=0
          fi
          write_state user-slice-limit "$value"
          ;;
        ManagedOOMSwap=*)
          write_state user-slice-swap "${property#*=}"
          ;;
      esac
    done
    ;;
  show\ user.slice\ -p\ ManagedOOMMemoryPressure\ -p\ ManagedOOMMemoryPressureLimit\ -p\ ManagedOOMSwap)
    printf 'ManagedOOMMemoryPressure=%s\n' \
      "$(state_value user-slice-pressure "${FAKE_MANAGED_OOM_MEMORY_PRESSURE:-auto}")"
    printf 'ManagedOOMMemoryPressureLimit=%s\n' \
      "$(state_value user-slice-limit "${FAKE_MANAGED_OOM_MEMORY_PRESSURE_LIMIT:-0}")"
    printf 'ManagedOOMSwap=%s\n' \
      "$(state_value user-slice-swap "${FAKE_MANAGED_OOM_SWAP:-kill}")"
    ;;
  daemon-reload)
    echo "systemctl $*" >> "$DEVBOX_TEST_LOG"
    if [ "${FAKE_DAEMON_RELOAD_RC:-0}" -ne 0 ]; then
      exit "$FAKE_DAEMON_RELOAD_RC"
    fi
    if [ -f "$DEVBOX_USER_SERVICE_DROPIN" ]; then
      write_state user-service-pressure auto
    else
      write_state user-service-pressure "${FAKE_USER_SERVICE_PRESSURE:-kill}"
    fi
    ;;
  *)
    echo "unexpected systemctl $*" >&2
    exit 1
    ;;
esac
EOF
  cat > "$fake_bin/rm" <<'EOF'
#!/usr/bin/env bash
for target in "$@"; do
  case "$target" in
    "$DEVBOX_USER_SERVICE_DROPIN"|"$DEVBOX_SESSION_SCOPE_DROPIN")
      echo "rm $*" >> "$DEVBOX_TEST_LOG"
      if [ "${FAKE_DROPIN_RM_RC:-0}" -ne 0 ]; then
        exit "$FAKE_DROPIN_RM_RC"
      fi
      break
      ;;
  esac
done
exec /usr/bin/rm "$@"
EOF
  cat > "$fake_bin/swapon" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--show=NAME" ]; then
  [ "${FAKE_SWAP_ACTIVE:-0}" = "1" ] && echo "$DEVBOX_SWAPFILE"
  exit 0
fi
echo "swapon $*" >> "$DEVBOX_TEST_LOG"
EOF
  cat > "$fake_bin/swapoff" <<'EOF'
#!/usr/bin/env bash
echo "swapoff $*" >> "$DEVBOX_TEST_LOG"
EOF
  cat > "$fake_bin/fallocate" <<'EOF'
#!/usr/bin/env bash
echo "fallocate $*" >> "$DEVBOX_TEST_LOG"
if [ "${FAKE_FALLOCATE_RC:-0}" -ne 0 ]; then
  exit "$FAKE_FALLOCATE_RC"
fi
# -l <size> <path>: sparse stand-in so stat/wc -c see the allocated size
/usr/bin/truncate -s "$2" "$3"
EOF
  cat > "$fake_bin/dd" <<'EOF'
#!/usr/bin/env bash
echo "dd $*" >> "$DEVBOX_TEST_LOG"
EOF
  cat > "$fake_bin/mkswap" <<'EOF'
#!/usr/bin/env bash
echo "mkswap $*" >> "$DEVBOX_TEST_LOG"
EOF
  cat > "$fake_bin/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$DEVBOX_TEST_LOG"
if [ "$*" = "install -y earlyoom" ]; then
  exit "${FAKE_APT_INSTALL_EARLYOOM_RC:-0}"
fi
EOF
  cat > "$fake_bin/apt-mark" <<'EOF'
#!/usr/bin/env bash
echo "apt-mark $*" >> "$DEVBOX_TEST_LOG"
exit "${FAKE_APT_MARK_RC:-0}"
EOF
  cat > "$fake_bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
if [ "${FAKE_EARLYOOM_INSTALLED:-1}" = 1 ]; then
  echo "${FAKE_EARLYOOM_DPKG_STATUS:-hold ok installed}"
else
  echo "dpkg-query: no packages found matching earlyoom" >&2
  exit 1
fi
EOF
  cat > "$fake_bin/earlyoom" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-v" ]; then
  echo "earlyoom ${FAKE_EARLYOOM_VERSION:-1.7.2}"
  exit 0
fi
EOF
  cat > "$fake_bin/sleep" <<'EOF'
#!/usr/bin/env bash
attempts_file="$DEVBOX_TEST_STATE_DIR/earlyoom-assert-sleeps"
attempts=0
if [ -f "$attempts_file" ]; then
  attempts="$(cat "$attempts_file")"
fi
attempts=$((attempts + 1))
printf '%s\n' "$attempts" > "$attempts_file"
if [ "${FAKE_EARLYOOM_EXEC_ON_SLEEP:-0}" = 1 ] \
  && [ -f "$DEVBOX_TEST_STATE_DIR/earlyoom-post-exec-cmdline" ]; then
  /usr/bin/cp "$DEVBOX_TEST_STATE_DIR/earlyoom-post-exec-cmdline" \
    "$DEVBOX_PROC_DIR/${FAKE_EARLYOOM_MAIN_PID:-4242}/cmdline"
fi
EOF
  cat > "$fake_bin/apt-cache" <<'EOF'
#!/usr/bin/env bash
echo "apt-cache $*" >> "$DEVBOX_TEST_LOG"
EOF
  chmod 0755 "$fake_bin"/*
}

run_hotfix() {
  local workdir="$1"
  shift

  DEVBOX_RUNTIME_STATE_DIR="$workdir/state" \
    DEVBOX_SYSCTL_CONF="$workdir/etc/sysctl.d/99-devbox-memory.conf" \
    DEVBOX_SWAPFILE="$workdir/swapfile" \
    DEVBOX_FSTAB="$workdir/etc/fstab" \
    DEVBOX_OOMD_CONF_DIR="$workdir/etc/systemd/oomd.conf.d" \
    DEVBOX_TEST_LOG="$workdir/commands.log" \
    DEVBOX_SWAP_SIZE_GIB="${DEVBOX_SWAP_SIZE_GIB:-0}" \
    DEVBOX_SWAPPINESS="${DEVBOX_SWAPPINESS:-60}" \
    DEVBOX_OOMD_SWAP_USED_LIMIT="${DEVBOX_OOMD_SWAP_USED_LIMIT:-95%}" \
    DEVBOX_EARLYOOM_ENABLED="${DEVBOX_EARLYOOM_ENABLED:-true}" \
    DEVBOX_EARLYOOM_MEM_PCT="${DEVBOX_EARLYOOM_MEM_PCT:-8,4}" \
    DEVBOX_EARLYOOM_SWAP_PCT="${DEVBOX_EARLYOOM_SWAP_PCT:-15,8}" \
    DEVBOX_EARLYOOM_AVOID_REGEX="${DEVBOX_EARLYOOM_AVOID_REGEX:-$default_avoid_regex}" \
    DEVBOX_EARLYOOM_DEFAULT="$workdir/etc/default/earlyoom" \
    DEVBOX_USER_SERVICE_DROPIN="$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" \
    DEVBOX_SESSION_SCOPE_DROPIN="$workdir/etc/systemd/system/session-.scope.d/50-devbox-oomd.conf" \
    DEVBOX_PROC_DIR="$workdir/proc" \
    DEVBOX_TEST_STATE_DIR="$workdir/test-state" \
    PATH="$workdir/fake-bin:$PATH" \
    "$repo_root/scripts/devbox-memory-hotfix" "$@"
}

setup_workdir() {
  local workdir="$1"

  mkdir -p "$workdir/etc/sysctl.d" "$workdir/etc/systemd/oomd.conf.d" \
    "$workdir/etc/default" "$workdir/etc/systemd/system/user@.service.d" \
    "$workdir/etc/systemd/system/session-.scope.d" "$workdir/proc" "$workdir/test-state"
  : > "$workdir/etc/fstab"
  make_fake_bin "$workdir/fake-bin"
}

write_earlyoom_cmdline() {
  local workdir="$1"
  shift
  local pid="${FAKE_EARLYOOM_MAIN_PID:-4242}"

  mkdir -p "$workdir/proc/$pid"
  printf '%s\0' /usr/bin/earlyoom "$@" > "$workdir/proc/$pid/cmdline"
}

# Converged earlyoom state: config on disk + running argv matching it.
seed_converged_earlyoom() {
  local workdir="$1"
  local args="${2:-$default_earlyoom_args}"
  local -a argv

  printf 'EARLYOOM_ARGS="%s"\n' "$args" > "$workdir/etc/default/earlyoom"
  read -r -a argv <<< "$args"
  write_earlyoom_cmdline "$workdir" "${argv[@]}"
}

seed_armed_state() {
  local workdir="$1"

  seed_converged_earlyoom "$workdir"
  printf '[Service]\nManagedOOMMemoryPressure=auto\n' \
    > "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf"
  printf '[Scope]\nManagedOOMPreference=avoid\n' \
    > "$workdir/etc/systemd/system/session-.scope.d/50-devbox-oomd.conf"
  printf 'auto\n' > "$workdir/test-state/user-service-pressure"
}

seed_legacy_user_slice_policy() {
  local workdir="$1"

  printf 'kill\n' > "$workdir/test-state/user-slice-pressure"
  printf '3006477107\n' > "$workdir/test-state/user-slice-limit"
  printf 'kill\n' > "$workdir/test-state/user-slice-swap"
}

assert_log_order() {
  local log="$1" first="$2" second="$3" l1 l2

  l1="$(grep -Fn "$first" "$log" | head -1 | cut -d: -f1 || true)"
  l2="$(grep -Fn "$second" "$log" | head -1 | cut -d: -f1 || true)"
  if [ -z "$l1" ]; then
    echo "--- command log ---" >&2
    cat "$log" >&2 || true
    fail "missing command log entry needed for ordering: $first"
  fi
  if [ -z "$l2" ]; then
    echo "--- command log ---" >&2
    cat "$log" >&2 || true
    fail "missing command log entry needed for ordering: $second"
  fi
  if [ "$l1" -ge "$l2" ]; then
    echo "--- command log ---" >&2
    cat "$log" >&2 || true
    fail "expected '$first' before '$second'"
  fi
}

test_assert_log_order_reports_missing_entries() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  printf 'second command\n' > "$workdir/commands.log"

  ( assert_log_order "$workdir/commands.log" "first command" "second command" ) \
    >"$workdir/assert.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "missing order entry must fail the assertion"
  grep -qF "missing command log entry needed for ordering: first command" \
    "$workdir/assert.out" \
    || fail "order assertion must identify the missing entry"
}

test_noop_skips_sysctl_set_property_and_restart() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf 'vm.swappiness=60\n' > "$workdir/etc/sysctl.d/99-devbox-memory.conf"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  FAKE_APT_INSTALL_EARLYOOM_RC=23 \
    run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_log_absent "$workdir/commands.log" "sysctl -p"
  assert_log_absent "$workdir/commands.log" "systemctl set-property user.slice"
  assert_log_absent "$workdir/commands.log" "systemctl restart systemd-oomd"
  assert_log_absent "$workdir/commands.log" "systemctl daemon-reload"
  assert_log_absent "$workdir/commands.log" "apt-get update"
  assert_log_absent "$workdir/commands.log" "apt-get install -y earlyoom"
  assert_log_absent "$workdir/commands.log" "systemctl mask earlyoom"
  assert_log_absent "$workdir/commands.log" "systemctl restart earlyoom"
  [ ! -e "$workdir/test-state/earlyoom-masked" ] \
    || fail "held steady-state earlyoom must never be left masked"
}

# Fleet root disks: 120G, ~72G avail with the old 32G swapfile in place. A
# 32→64 resize must count the doomed swapfile as reclaimable space.
test_swap_resize_counts_existing_swapfile_as_reclaimable() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  truncate -s 32G "$workdir/swapfile"

  DEVBOX_SWAP_SIZE_GIB=64 FAKE_ROOT_AVAIL_G=72 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1

  if grep -qF "leaving current swapfile active" "$workdir/hotfix.out"; then
    fail "resize must proceed when avail plus the old swapfile covers swap+reserve"
  fi
  assert_log_contains "$workdir/commands.log" "swapoff $workdir/swapfile"
  assert_log_contains "$workdir/commands.log" "fallocate -l 64G $workdir/swapfile"
  assert_log_contains "$workdir/commands.log" "mkswap $workdir/swapfile"
  [ "$(stat -c '%s' "$workdir/swapfile")" -eq $((64 * 1024 * 1024 * 1024)) ] \
    || fail "recreated swapfile must be 64GiB"
}

test_swap_resize_skips_when_reclaim_still_insufficient() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  truncate -s 32G "$workdir/swapfile"

  # 40 avail + 32 reclaimable = 72 < 64 swap + 12 reserve
  DEVBOX_SWAP_SIZE_GIB=64 FAKE_ROOT_AVAIL_G=40 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1

  grep -qF "leaving current swapfile active" "$workdir/hotfix.out" \
    || fail "insufficient space even after reclaim must warn and keep the old swapfile"
  assert_log_absent "$workdir/commands.log" "swapoff $workdir/swapfile"
  assert_log_absent "$workdir/commands.log" "fallocate"
  [ "$(stat -c '%s' "$workdir/swapfile")" -eq $((32 * 1024 * 1024 * 1024)) ] \
    || fail "old swapfile must remain untouched"
}

test_swap_creation_without_swapfile_reclaims_nothing() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"

  DEVBOX_SWAP_SIZE_GIB=64 FAKE_ROOT_AVAIL_G=72 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "fresh creation with insufficient free space must stay FATAL"
  grep -qF "GiB free; need" "$workdir/hotfix.out" \
    || fail "creation-path failure must emit the free-space diagnostic"
  [ ! -s "$workdir/commands.log" ] \
    || fail "creation-path FATAL must abort before touching anything"
}

test_user_slice_drift_sets_property_without_oomd_restart() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf 'vm.swappiness=60\n' > "$workdir/etc/sysctl.d/99-devbox-memory.conf"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  FAKE_MANAGED_OOM_MEMORY_PRESSURE=kill \
    FAKE_MANAGED_OOM_MEMORY_PRESSURE_LIMIT=3006477107 \
    run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_log_contains "$workdir/commands.log" \
    "systemctl set-property user.slice ManagedOOMMemoryPressure=auto ManagedOOMMemoryPressureLimit=0% ManagedOOMSwap=kill"
  assert_state_value "$workdir" user-slice-limit 0
  assert_log_absent "$workdir/commands.log" "systemctl restart systemd-oomd"
}

test_stale_duration_key_rewrites_conf_and_restarts_oomd() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf 'vm.swappiness=60\n' > "$workdir/etc/sysctl.d/99-devbox-memory.conf"
  printf '[OOM]\nDefaultMemoryPressureDurationSec=30s\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_log_contains "$workdir/commands.log" "systemctl restart systemd-oomd"
  grep -qF "SwapUsedLimit=95%" "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf" \
    || fail "oomd config should carry SwapUsedLimit"
  if grep -q "DefaultMemoryPressureDurationSec" "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"; then
    fail "duration key must be dropped (no pressure-kill anywhere)"
  fi
}

test_first_arming_writes_dropins_and_markers() {
  local workdir expected_env_sha expected_oomd_sha
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_converged_earlyoom "$workdir"   # earlyoom converged, but NOT yet armed

  run_hotfix "$workdir" >"$workdir/hotfix.out"

  printf '[Service]\nManagedOOMMemoryPressure=auto\n' > "$workdir/expected-user-dropin"
  cmp -s "$workdir/expected-user-dropin" \
    "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" \
    || fail "user@.service drop-in content mismatch"
  printf '[Scope]\nManagedOOMPreference=avoid\n' > "$workdir/expected-session-dropin"
  cmp -s "$workdir/expected-session-dropin" \
    "$workdir/etc/systemd/system/session-.scope.d/50-devbox-oomd.conf" \
    || fail "session scope drop-in content mismatch"
  assert_log_contains "$workdir/commands.log" "systemctl daemon-reload"

  expected_env_sha="$(printf 'swap_size_gib=%s\nswappiness=%s\nroot_free_reserve_gib=%s\nearlyoom_enabled=%s\nearlyoom_mem_pct=%s\nearlyoom_swap_pct=%s\nearlyoom_avoid_regex=%s\n' \
    0 60 12 true "8,4" "15,8" "$default_avoid_regex" | sha256sum | awk '{print $1}')"
  [ "$(cat "$workdir/state/memory.env.sha256")" = "$expected_env_sha" ] \
    || fail "memory.env.sha256 must cover the earlyoom knobs"
  expected_oomd_sha="$(printf 'pressure=auto\nswap=kill\nswap_used_limit=%s\n' "95%" | sha256sum | awk '{print $1}')"
  [ "$(cat "$workdir/state/oomd.conf.sha256")" = "$expected_oomd_sha" ] \
    || fail "oomd.conf.sha256 must reflect the demoted policy"
}

test_invalid_earlyoom_thresholds_abort_before_any_action() {
  local workdir bad rc
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"

  for bad in "999,4" "4,8" "8" "0,4" "8,0" "8,4,2" "a,b"; do
    rc=0
    DEVBOX_EARLYOOM_MEM_PCT="$bad" run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "expected DEVBOX_EARLYOOM_MEM_PCT=$bad to abort"
    [ ! -s "$workdir/commands.log" ] || fail "invalid mem pct '$bad' must abort before touching anything"
    rc=0
    DEVBOX_EARLYOOM_SWAP_PCT="$bad" run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "expected DEVBOX_EARLYOOM_SWAP_PCT=$bad to abort"
    [ ! -s "$workdir/commands.log" ] || fail "invalid swap pct '$bad' must abort before touching anything"
  done

  rc=0
  DEVBOX_EARLYOOM_ENABLED="yes" run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "expected DEVBOX_EARLYOOM_ENABLED=yes to abort"
  [ ! -s "$workdir/commands.log" ] \
    || fail "invalid enabled value must abort before touching anything"
}

test_huge_earlyoom_mem_threshold_aborts_without_numeric_errors() {
  local workdir huge pair rc
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  huge="$(printf '%0200d' 0 | tr '0' '9')"

  for pair in "${huge},4" "8,${huge}"; do
    : > "$workdir/commands.log"
    rc=0
    DEVBOX_EARLYOOM_MEM_PCT="$pair" \
      run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "huge mem percentage must be rejected: $pair"
    grep -qF "percentages must be 1-100" "$workdir/hotfix.out" \
      || fail "huge mem percentage must emit the validation diagnostic"
    if grep -qF "integer expression expected" "$workdir/hotfix.out"; then
      fail "huge mem percentage reached Bash numeric test"
    fi
    [ ! -s "$workdir/commands.log" ] \
      || fail "huge mem percentage must abort before touching anything"
  done
}

test_huge_earlyoom_swap_threshold_aborts_without_numeric_errors() {
  local workdir huge pair rc
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  huge="$(printf '%0200d' 0 | tr '0' '9')"

  for pair in "${huge},4" "8,${huge}"; do
    : > "$workdir/commands.log"
    rc=0
    DEVBOX_EARLYOOM_SWAP_PCT="$pair" \
      run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "huge swap percentage must be rejected: $pair"
    grep -qF "percentages must be 1-100" "$workdir/hotfix.out" \
      || fail "huge swap percentage must emit the validation diagnostic"
    if grep -qF "integer expression expected" "$workdir/hotfix.out"; then
      fail "huge swap percentage reached Bash numeric test"
    fi
    [ ! -s "$workdir/commands.log" ] \
      || fail "huge swap percentage must abort before touching anything"
  done
}

test_invalid_avoid_regex_aborts_before_any_action() {
  local workdir bad rc
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"

  # whitespace / quotes break unquoted $EARLYOOM_ARGS expansion; '(' fails ERE compile
  for bad in '^(a b)$' '^"foo"$' "^'foo'\$" '('; do
    rc=0
    DEVBOX_EARLYOOM_AVOID_REGEX="$bad" run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "expected DEVBOX_EARLYOOM_AVOID_REGEX='$bad' to abort"
    [ ! -s "$workdir/commands.log" ] || fail "invalid regex '$bad' must abort before touching anything"
  done
}

test_fresh_install_masks_before_install_and_renders_config() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  # package absent; running argv will match the rendered default config
  write_earlyoom_cmdline "$workdir" -m 8,4 -s 15,8 -r 3600 --avoid "$default_avoid_regex"

  FAKE_EARLYOOM_INSTALLED=0 run_hotfix "$workdir" >"$workdir/hotfix.out"

  # Mask must precede install: the postinst's deb-systemd-invoke start respects
  # masking, so packaged default thresholds never run.
  assert_log_order "$workdir/commands.log" "systemctl mask earlyoom" "apt-get install -y earlyoom"
  assert_log_order "$workdir/commands.log" "apt-get install -y earlyoom" "systemctl unmask earlyoom"
  assert_log_contains "$workdir/commands.log" "apt-mark hold earlyoom"
  assert_log_contains "$workdir/commands.log" "systemctl enable --now earlyoom"

  printf 'EARLYOOM_ARGS="%s"\n' "$default_earlyoom_args" > "$workdir/expected-earlyoom"
  cmp -s "$workdir/expected-earlyoom" "$workdir/etc/default/earlyoom" \
    || fail "rendered /etc/default/earlyoom does not match the fleet default args"
}

test_threshold_change_rewrites_config_and_restarts_earlyoom() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_converged_earlyoom "$workdir"
  # the post-restart argv the assert will see
  write_earlyoom_cmdline "$workdir" -m 10,5 -s 15,8 -r 3600 --avoid "$default_avoid_regex"

  DEVBOX_EARLYOOM_MEM_PCT="10,5" run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_log_contains "$workdir/commands.log" "systemctl restart earlyoom"
  assert_log_absent "$workdir/commands.log" "apt-get install -y earlyoom"
  grep -qF -- "-m 10,5" "$workdir/etc/default/earlyoom" \
    || fail "config should carry the new -m tier"
}

test_argv_with_extra_flags_fails_verification() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_converged_earlyoom "$workdir"
  # extra trailing flag would OVERRIDE the rendered -m tier (last flag wins)
  write_earlyoom_cmdline "$workdir" -m 8,4 -s 15,8 -r 3600 --avoid "$default_avoid_regex" -m 50

  DEVBOX_EARLYOOM_MEM_PCT="8,4" run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "an argv with extra overriding flags must fail verification"
  grep -qF "ERROR: running earlyoom argv is not exactly the rendered config" \
    "$workdir/hotfix.out" \
    || fail "extra argv failure must identify the exact-argv mismatch"
  assert_log_absent "$workdir/commands.log" "systemctl set-property user.slice"
  assert_log_absent "$workdir/commands.log" "systemctl restart systemd-oomd"
  assert_log_absent "$workdir/commands.log" "systemctl daemon-reload"
}

test_earlyoom_assert_waits_for_systemd_executor_exec() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  printf 'EARLYOOM_ARGS="%s"\n' "$default_earlyoom_args" \
    > "$workdir/etc/default/earlyoom"
  mkdir -p "$workdir/proc/4242"
  printf '%s\0' '(earlyoom)' > "$workdir/proc/4242/cmdline"
  printf '%s\0' /usr/bin/earlyoom -m 8,4 -s 15,8 -r 3600 --avoid \
    "$default_avoid_regex" \
    > "$workdir/test-state/earlyoom-post-exec-cmdline"

  FAKE_EARLYOOM_EXEC_ON_SLEEP=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_state_value "$workdir" earlyoom-assert-sleeps 1
  [ -f "$workdir/state/memory.env.sha256" ] \
    || fail "converge must finish after earlyoom exec reaches the exact argv"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
}

test_main_pid_query_failure_emits_custom_error() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_converged_earlyoom "$workdir"

  FAKE_EARLYOOM_MAIN_PID_QUERY_RC=23 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "a failed MainPID query must abort verification"
  grep -qF "ERROR: could not query earlyoom MainPID" \
    "$workdir/hotfix.out" \
    || fail "failed MainPID query must emit the custom diagnostic"
}

test_earlyoom_config_parser_requires_one_nonempty_assignment() {
  local workdir output config accepted=""
  trap - RETURN
  source <(sed -n '/^earlyoom_args_from_config()/,/^}/p' "$repo_root/scripts/devbox-memory-hotfix")
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN

  printf 'EARLYOOM_ARGS="-m 8,4"\n' > "$workdir/valid"
  output="$(earlyoom_args_from_config "$workdir/valid")"
  [ "$output" = "-m 8,4" ] || fail "valid earlyoom config should return its args"

  printf 'EARLYOOM_ARGS=""\n' > "$workdir/empty"
  printf 'EARLYOOM_ARGS="-m 8,4"\nEARLYOOM_ARGS="-s 15,8"\n' > "$workdir/duplicate"
  printf 'EARLYOOM_ARGS="-m 8,4"\nEARLYOOM_ARGS=""\n' > "$workdir/trailing-empty"
  printf 'EARLYOOM_ARGS="-m 8,4"junk"\n' > "$workdir/embedded-quote"
  printf 'EARLYOOM_ARGS=malformed\nEARLYOOM_ARGS="-m 8,4"\n' > "$workdir/malformed-plus-valid"

  for config in missing empty duplicate trailing-empty embedded-quote malformed-plus-valid; do
    if earlyoom_args_from_config "$workdir/$config" >/dev/null; then
      accepted="$accepted $config"
    fi
  done
  [ -z "$accepted" ] || fail "earlyoom config parser accepted invalid assignments:$accepted"
}

test_apt_failure_aborts_pre_handoff_old_regime_intact() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_legacy_user_slice_policy "$workdir"

  FAKE_EARLYOOM_INSTALLED=0 FAKE_APT_INSTALL_EARLYOOM_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "apt failure must abort the converge"
  [ ! -f "$workdir/etc/default/earlyoom" ] \
    || fail "config must be untouched — it is only written post-install"
  assert_log_contains "$workdir/commands.log" "systemctl disable --now earlyoom"
  assert_log_order "$workdir/commands.log" "systemctl mask earlyoom" "systemctl unmask earlyoom"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "oomd demotion drop-in must not exist after a pre-handoff failure"
  assert_log_absent "$workdir/commands.log" \
    "ManagedOOMMemoryPressure=auto ManagedOOMMemoryPressureLimit="
  assert_state_value "$workdir" user-slice-pressure kill
  assert_state_value "$workdir" user-slice-limit 3006477107
  assert_state_value "$workdir" user-slice-swap kill
}

test_hold_failure_aborts_pre_handoff() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"

  FAKE_EARLYOOM_INSTALLED=0 FAKE_APT_MARK_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "apt-mark hold failure must abort the converge"
  [ ! -f "$workdir/etc/default/earlyoom" ] || fail "config must be untouched"
  assert_log_contains "$workdir/commands.log" "systemctl disable --now earlyoom"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "no demotion after pre-handoff failure"
}

test_unmask_failure_aborts_pre_handoff() {
  local workdir rc=0 unmask_count
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"

  FAKE_EARLYOOM_INSTALLED=0 FAKE_EARLYOOM_UNMASK_FAIL_ONCE=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "unmask failure must abort the converge"
  assert_log_contains "$workdir/commands.log" "systemctl disable --now earlyoom"
  unmask_count="$(grep -cF "systemctl unmask earlyoom" "$workdir/commands.log")"
  [ "$unmask_count" -eq 2 ] \
    || fail "one-shot unmask failure must be retried by cleanup"
  grep -qF "earlyoom stopped and disabled; old oomd policy intact" \
    "$workdir/hotfix.out" \
    || fail "successful cleanup retry must report old-regime recovery"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "no demotion after pre-handoff failure"
}

test_pre_handoff_disable_cleanup_failure_is_reported() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"

  FAKE_EARLYOOM_INSTALLED=0 FAKE_APT_INSTALL_EARLYOOM_RC=23 \
    FAKE_EARLYOOM_DISABLE_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -eq 23 ] \
    || fail "cleanup must preserve the triggering apt failure status (got: $rc)"
  grep -qF "ERROR: earlyoom pre-handoff cleanup incomplete" \
    "$workdir/hotfix.out" \
    || fail "disable cleanup failure must be reported explicitly"
  if grep -qF "earlyoom stopped and disabled; old oomd policy intact" \
    "$workdir/hotfix.out"; then
    fail "disable cleanup failure must never claim successful cleanup"
  fi
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "failed earlyoom cleanup must still leave old oomd untouched"
}

test_pre_handoff_unmask_cleanup_failure_is_reported() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"

  FAKE_EARLYOOM_INSTALLED=0 FAKE_EARLYOOM_UNMASK_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "persistent unmask failure must abort the converge"
  grep -qF "ERROR: earlyoom pre-handoff cleanup incomplete" \
    "$workdir/hotfix.out" \
    || fail "unmask cleanup failure must be reported explicitly"
  if grep -qF "earlyoom stopped and disabled; old oomd policy intact" \
    "$workdir/hotfix.out"; then
    fail "unmask cleanup failure must never claim successful cleanup"
  fi
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "failed mask cleanup must still leave old oomd untouched"
}

test_service_refusing_start_aborts_pre_handoff() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"

  FAKE_EARLYOOM_INSTALLED=0 FAKE_EARLYOOM_ACTIVE_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "a service that refuses to start must abort the converge"
  assert_log_contains "$workdir/commands.log" "systemctl disable --now earlyoom"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "pressure policy must be old-regime after a pre-handoff failure"
}

test_armed_restart_failure_restores_last_known_good() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  mkdir -p "$workdir/tmp"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  TMPDIR="$workdir/tmp" DEVBOX_EARLYOOM_MEM_PCT="10,5" FAKE_EARLYOOM_RESTART_FAIL_ONCE=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "failed restart on an armed box must abort the converge"
  printf 'EARLYOOM_ARGS="%s"\n' "$default_earlyoom_args" > "$workdir/expected-earlyoom"
  cmp -s "$workdir/expected-earlyoom" "$workdir/etc/default/earlyoom" \
    || fail "snapshot config must be restored (last-known-good)"
  [ -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "demotion drop-ins must survive a successful restore"
  [ -f "$workdir/etc/systemd/system/session-.scope.d/50-devbox-oomd.conf" ] \
    || fail "session drop-in must survive a successful restore"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  [ "$(grep -c "systemctl restart earlyoom" "$workdir/commands.log")" -eq 2 ] \
    || fail "expected the failed restart plus the recovery restart"
  if find "$workdir/tmp" -type f -print -quit | grep -q .; then
    fail "armed recovery must clean its transaction snapshot before exit"
  fi
}

test_armed_missing_prior_config_falls_back_to_stock_oomd() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  printf '[Service]\nManagedOOMMemoryPressure=auto\n' \
    > "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf"
  printf '[Scope]\nManagedOOMPreference=avoid\n' \
    > "$workdir/etc/systemd/system/session-.scope.d/50-devbox-oomd.conf"
  write_earlyoom_cmdline "$workdir" -m 8,4 -s 15,8 -r 3600 --avoid "$default_avoid_regex"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  FAKE_EARLYOOM_RESTART_FAIL_ONCE=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "failed armed replacement without a prior config must abort"
  if grep -qF "restored on last-known-good" "$workdir/hotfix.out"; then
    fail "newly rendered config must not be reported as last-known-good"
  fi
  assert_log_contains "$workdir/commands.log" "systemctl disable --now earlyoom"
  [ "$(grep -c "systemctl restart earlyoom" "$workdir/commands.log")" -eq 1 ] \
    || fail "missing prior config must skip retry of the newly rendered config"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "missing prior config must fall back to stock oomd"
}

test_armed_snapshot_restore_install_failure_falls_back_to_stock_oomd() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  # If restore fails, the running argv matches the newly rendered config.
  # Recovery must not mistake that config for the prior last-known-good.
  write_earlyoom_cmdline "$workdir" -m 10,5 -s 15,8 -r 3600 --avoid "$default_avoid_regex"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_MEM_PCT="10,5" \
    FAKE_EARLYOOM_RESTART_FAIL_ONCE=1 \
    FAKE_EARLYOOM_DEFAULT_INSTALL_FAIL_ON_ATTEMPT=2 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "snapshot restore install failure must abort"
  if grep -qF "restored on last-known-good" "$workdir/hotfix.out"; then
    fail "failed snapshot install must never report last-known-good recovery"
  fi
  assert_log_contains "$workdir/commands.log" "systemctl disable --now earlyoom"
  [ "$(grep -c "systemctl restart earlyoom" "$workdir/commands.log")" -eq 1 ] \
    || fail "failed snapshot install must skip retry of the newly rendered config"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "failed snapshot install must fall back to stock oomd"
}

test_armed_successful_replacement_cleans_snapshot() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  mkdir -p "$workdir/tmp"
  seed_armed_state "$workdir"
  write_earlyoom_cmdline "$workdir" -m 10,5 -s 15,8 -r 3600 --avoid "$default_avoid_regex"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  TMPDIR="$workdir/tmp" DEVBOX_EARLYOOM_MEM_PCT="10,5" \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1

  if find "$workdir/tmp" -type f -print -quit | grep -q .; then
    fail "successful armed replacement must clean its transaction snapshot"
  fi
}

test_armed_unrevivable_restores_stock_oomd() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_MEM_PCT="10,5" FAKE_EARLYOOM_RESTART_RC=1 FAKE_EARLYOOM_ACTIVE_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "unrevivable earlyoom must abort the converge"
  # falls back to the earlyoom_enabled=false state: stock oomd pressure-kill,
  # restored BEFORE earlyoom is stopped (the transaction ordering invariant)
  assert_log_order "$workdir/commands.log" "systemctl daemon-reload" "systemctl disable --now earlyoom"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "user@ drop-in must be removed so stock 50% pressure-kill returns"
  [ ! -f "$workdir/etc/systemd/system/session-.scope.d/50-devbox-oomd.conf" ] \
    || fail "session drop-in must be removed"
}

test_armed_recovery_rejects_malformed_config() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  # armed box whose pre-existing config is garbage: the snapshot the trap
  # restores will not parse, and MUST count as unrevivable — an empty parse
  # result must never wildcard-match the running argv
  printf '[Service]\nManagedOOMMemoryPressure=auto\n' \
    > "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf"
  printf '[Scope]\nManagedOOMPreference=avoid\n' \
    > "$workdir/etc/systemd/system/session-.scope.d/50-devbox-oomd.conf"
  printf '# malformed: no EARLYOOM_ARGS line\n' > "$workdir/etc/default/earlyoom"
  write_earlyoom_cmdline "$workdir" -m 8,4 -s 15,8 -r 3600 --avoid "$default_avoid_regex"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  FAKE_EARLYOOM_RESTART_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "recovery with an unparseable config must abort"
  grep -q "restored on last-known-good" "$workdir/hotfix.out" \
    && fail "an unparseable config must never be reported as restored"
  assert_log_contains "$workdir/commands.log" "systemctl disable --now earlyoom"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "unparseable config must land in stock oomd, drop-ins removed"
}

test_armed_version_assert_failure_lands_in_stock_oomd() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  # simulated hold bypass: binary is 1.8, restore cannot fix that
  FAKE_EARLYOOM_VERSION="1.8.0" \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "version assert failure must abort the converge"
  [ "$(grep -c "systemctl restart earlyoom" "$workdir/commands.log")" -eq 1 ] \
    || fail "unchanged current config must be retried before stock oomd fallback"
  assert_log_contains "$workdir/commands.log" "systemctl disable --now earlyoom"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "an unsupported binary must not be left as the only responder"
}

test_armed_unrevivable_verifies_stock_pressure_before_disable() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  write_earlyoom_cmdline "$workdir" -m 8,4 -s 15,8 -r 3600 \
    --avoid "$default_avoid_regex" -m 50

  run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "unrevivable earlyoom must abort the converge"
  assert_log_order "$workdir/commands.log" \
    "systemctl daemon-reload" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value"
  assert_log_order "$workdir/commands.log" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value" \
    "systemctl disable --now earlyoom"
}

test_armed_stock_pressure_verification_failure_never_disables_earlyoom() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  write_earlyoom_cmdline "$workdir" -m 8,4 -s 15,8 -r 3600 \
    --avoid "$default_avoid_regex" -m 50

  FAKE_USER_SERVICE_PRESSURE=auto \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "unverified stock pressure must abort the recovery"
  assert_log_contains "$workdir/commands.log" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  grep -qF "stock oomd pressure-kill was not restored" "$workdir/hotfix.out" \
    || fail "stock pressure verification failure must abort loudly"
}

test_rollback_restores_stock_pressure_before_disabling_earlyoom() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false run_hotfix "$workdir" >"$workdir/hotfix.out"

  # Active-user case: oomd is active, both overrides are removed, and the
  # concrete unit's effective policy plus final user.slice backstop are
  # verified BEFORE earlyoom is stopped.
  assert_log_order "$workdir/commands.log" \
    "systemctl enable --now systemd-oomd" \
    "systemctl is-active --quiet systemd-oomd"
  assert_log_order "$workdir/commands.log" \
    "systemctl is-active --quiet systemd-oomd" \
    "rm -f $workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf"
  assert_log_order "$workdir/commands.log" \
    "rm -f $workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" \
    "systemctl daemon-reload"
  assert_log_order "$workdir/commands.log" \
    "systemctl daemon-reload" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value"
  assert_log_order "$workdir/commands.log" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value" \
    "systemctl show user.slice -p ManagedOOMMemoryPressure --value"
  assert_log_order "$workdir/commands.log" \
    "systemctl show user.slice -p ManagedOOMSwap --value" \
    "systemctl disable --now earlyoom"
  assert_log_absent "$workdir/commands.log" \
    "systemctl show user@.service -p ManagedOOMMemoryPressure --value"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "rollback must remove the user@ drop-in (stock 50% pressure-kill returns)"
  [ ! -f "$workdir/etc/systemd/system/session-.scope.d/50-devbox-oomd.conf" ] \
    || fail "rollback must remove the session drop-in"
  grep -qF "SwapUsedLimit=95%" "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf" \
    || fail "swap backstop must survive rollback"
  assert_log_absent "$workdir/commands.log" "apt-get install -y earlyoom"
}

test_rollback_succeeds_with_inactive_user_manager() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_USER_SERVICE_ACTIVE_RC=3 \
    run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_log_contains "$workdir/commands.log" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value"
  assert_log_absent "$workdir/commands.log" \
    "systemctl is-active --quiet user@1000.service"
  assert_log_order "$workdir/commands.log" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value" \
    "systemctl disable --now earlyoom"
}

test_rollback_reload_failure_leaves_earlyoom_active() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_DAEMON_RELOAD_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "a failed daemon-reload must abort the rollback"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
}

test_rollback_inactive_reload_failure_keeps_emergency_responder() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_EARLYOOM_ACTIVE_RC=1 \
    FAKE_DAEMON_RELOAD_RC=29 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "inactive rollback with failed reload must abort"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  assert_state_value "$workdir" user-slice-pressure kill
  assert_state_value "$workdir" user-slice-limit 3006477107
  assert_state_value "$workdir" user-slice-swap kill
  assert_log_order "$workdir/commands.log" \
    "systemctl set-property user.slice ManagedOOMMemoryPressure=kill ManagedOOMMemoryPressureLimit=70% ManagedOOMSwap=kill" \
    "systemctl enable --now systemd-oomd"
  assert_log_order "$workdir/commands.log" \
    "systemctl is-active --quiet systemd-oomd" \
    "rm -f $workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf"
  assert_log_order "$workdir/commands.log" \
    "rm -f $workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" \
    "systemctl daemon-reload"
}

test_rollback_inactive_success_restores_final_state_before_disable() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_EARLYOOM_ACTIVE_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_log_order "$workdir/commands.log" \
    "systemctl set-property user.slice ManagedOOMMemoryPressure=kill ManagedOOMMemoryPressureLimit=70% ManagedOOMSwap=kill" \
    "systemctl daemon-reload"
  assert_log_order "$workdir/commands.log" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value" \
    "systemctl set-property user.slice ManagedOOMMemoryPressure=auto ManagedOOMMemoryPressureLimit=0% ManagedOOMSwap=kill"
  assert_log_order "$workdir/commands.log" \
    "systemctl set-property user.slice ManagedOOMMemoryPressure=auto ManagedOOMMemoryPressureLimit=0% ManagedOOMSwap=kill" \
    "systemctl disable --now earlyoom"
  assert_state_value "$workdir" user-slice-pressure auto
  assert_state_value "$workdir" user-slice-limit 0
  assert_state_value "$workdir" user-slice-swap kill
  assert_state_value "$workdir" user-service-pressure kill
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "successful inactive rollback must remove the user service override"
  [ ! -f "$workdir/etc/systemd/system/session-.scope.d/50-devbox-oomd.conf" ] \
    || fail "successful inactive rollback must remove the session override"
}

test_rollback_inactive_query_failure_keeps_emergency_responder() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_EARLYOOM_ACTIVE_RC=1 \
    FAKE_USER_SERVICE_QUERY_RC=23 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "inactive rollback with failed user query must abort"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  assert_state_value "$workdir" user-slice-pressure kill
  assert_state_value "$workdir" user-slice-limit 3006477107
  assert_state_value "$workdir" user-slice-swap kill
  assert_log_order "$workdir/commands.log" \
    "systemctl daemon-reload" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value"
  assert_log_absent "$workdir/commands.log" \
    "systemctl is-active --quiet user@1000.service"
  assert_log_contains "$workdir/commands.log" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value"
  grep -qF "ERROR: could not verify stock oomd pressure-kill" \
    "$workdir/hotfix.out" \
    || fail "failed concrete user query must emit the stock responder diagnostic"
}

test_rollback_reports_failed_emergency_reactivation_honestly() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_EARLYOOM_ACTIVE_RC=1 \
    FAKE_USER_SERVICE_QUERY_FAIL_ON_ATTEMPT=2 \
    FAKE_USER_SLICE_SET_PROPERTY_FAIL_ON_ATTEMPT=3 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "failed final stock check must abort rollback"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  if grep -qF "emergency policy re-applied" "$workdir/hotfix.out"; then
    fail "failed emergency reactivation must not be reported as successful"
  fi
  grep -qF "ERROR: emergency policy reactivation failed; no responder could be reverified" \
    "$workdir/hotfix.out" \
    || fail "failed emergency reactivation must emit the invariant warning"
}

test_rollback_inactive_oomd_start_failure_keeps_emergency_config() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_EARLYOOM_ACTIVE_RC=1 \
    FAKE_OOMD_ENABLE_NOW_RC=25 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "inactive rollback with failed oomd start must abort"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  assert_log_absent "$workdir/commands.log" "systemctl daemon-reload"
  assert_state_value "$workdir" user-slice-pressure kill
  assert_state_value "$workdir" user-slice-limit 3006477107
  assert_state_value "$workdir" user-slice-swap kill
  assert_log_contains "$workdir/commands.log" "systemctl enable --now systemd-oomd"
}

test_rollback_inactive_oomd_active_failure_keeps_emergency_config() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_EARLYOOM_ACTIVE_RC=1 \
    FAKE_OOMD_ACTIVE_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "inactive rollback with inactive oomd must abort"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  assert_log_absent "$workdir/commands.log" "systemctl daemon-reload"
  assert_state_value "$workdir" user-slice-pressure kill
  assert_state_value "$workdir" user-slice-limit 3006477107
  assert_state_value "$workdir" user-slice-swap kill
  assert_log_order "$workdir/commands.log" \
    "systemctl enable --now systemd-oomd" \
    "systemctl is-active --quiet systemd-oomd"
}

test_rollback_inactive_dropin_remove_failure_keeps_emergency_responder() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_EARLYOOM_ACTIVE_RC=1 \
    FAKE_DROPIN_RM_RC=31 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "inactive rollback with failed drop-in removal must abort"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  assert_log_absent "$workdir/commands.log" "systemctl daemon-reload"
  assert_state_value "$workdir" user-slice-pressure kill
  assert_state_value "$workdir" user-slice-limit 3006477107
  assert_state_value "$workdir" user-slice-swap kill
  grep -qF "ERROR: could not remove oomd demotion drop-ins" \
    "$workdir/hotfix.out" \
    || fail "drop-in removal failure must be reported directly"
}

test_rollback_retries_reload_after_reload_failure_removed_dropins() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_DAEMON_RELOAD_RC=1 \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "first rollback must fail at daemon-reload"
  [ ! -f "$workdir/etc/systemd/system/user@.service.d/50-devbox-oomd.conf" ] \
    || fail "failed reload should leave the removed drop-in pending activation"

  : > "$workdir/commands.log"
  DEVBOX_EARLYOOM_ENABLED=false \
    run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_log_order "$workdir/commands.log" \
    "systemctl daemon-reload" \
    "systemctl disable --now earlyoom"
}

test_rollback_pressure_verify_failure_leaves_earlyoom_active() {
  local workdir rc=0
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  # stock pressure-kill did NOT come back (e.g. another override shadows it)
  DEVBOX_EARLYOOM_ENABLED=false FAKE_USER_SERVICE_PRESSURE=auto \
    run_hotfix "$workdir" >"$workdir/hotfix.out" 2>&1 || rc=$?

  [ "$rc" -ne 0 ] || fail "unverified stock pressure must abort the rollback"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
}

test_rollback_is_idempotent() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf 'vm.swappiness=60\n' > "$workdir/etc/sysctl.d/99-devbox-memory.conf"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false \
    run_hotfix "$workdir" >"$workdir/hotfix.out"
  : > "$workdir/commands.log"
  DEVBOX_EARLYOOM_ENABLED=false \
    run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  assert_log_absent "$workdir/commands.log" "systemctl daemon-reload"
  assert_log_absent "$workdir/commands.log" "systemctl set-property user.slice"
}

test_rollback_with_inactive_user_manager_is_idempotent() {
  local workdir
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' RETURN
  setup_workdir "$workdir"
  seed_armed_state "$workdir"
  printf 'vm.swappiness=60\n' > "$workdir/etc/sysctl.d/99-devbox-memory.conf"
  printf '[OOM]\nSwapUsedLimit=95%%\n' > "$workdir/etc/systemd/oomd.conf.d/50-devbox.conf"

  DEVBOX_EARLYOOM_ENABLED=false FAKE_USER_SERVICE_ACTIVE_RC=3 \
    run_hotfix "$workdir" >"$workdir/hotfix.out"
  : > "$workdir/commands.log"
  DEVBOX_EARLYOOM_ENABLED=false FAKE_USER_SERVICE_ACTIVE_RC=3 \
    run_hotfix "$workdir" >"$workdir/hotfix.out"

  assert_log_contains "$workdir/commands.log" \
    "systemctl show user@1000.service -p ManagedOOMMemoryPressure --value"
  assert_log_absent "$workdir/commands.log" \
    "systemctl is-active --quiet user@1000.service"
  assert_log_absent "$workdir/commands.log" "systemctl disable --now earlyoom"
  assert_log_absent "$workdir/commands.log" "systemctl daemon-reload"
  assert_log_absent "$workdir/commands.log" "systemctl set-property user.slice"
}

test_count=0
run_test() {
  local name="$1"

  case ",${DEVBOX_TEST_ONLY:-}," in
    ,,|*,"$name",*)
      test_count=$((test_count + 1))
      ( "$name" )
      ;;
  esac
}

run_test test_assert_log_order_reports_missing_entries
run_test test_noop_skips_sysctl_set_property_and_restart
run_test test_swap_resize_counts_existing_swapfile_as_reclaimable
run_test test_swap_resize_skips_when_reclaim_still_insufficient
run_test test_swap_creation_without_swapfile_reclaims_nothing
run_test test_user_slice_drift_sets_property_without_oomd_restart
run_test test_stale_duration_key_rewrites_conf_and_restarts_oomd
run_test test_first_arming_writes_dropins_and_markers
run_test test_invalid_earlyoom_thresholds_abort_before_any_action
run_test test_huge_earlyoom_mem_threshold_aborts_without_numeric_errors
run_test test_huge_earlyoom_swap_threshold_aborts_without_numeric_errors
run_test test_invalid_avoid_regex_aborts_before_any_action
run_test test_fresh_install_masks_before_install_and_renders_config
run_test test_threshold_change_rewrites_config_and_restarts_earlyoom
run_test test_argv_with_extra_flags_fails_verification
run_test test_earlyoom_assert_waits_for_systemd_executor_exec
run_test test_main_pid_query_failure_emits_custom_error
run_test test_earlyoom_config_parser_requires_one_nonempty_assignment
run_test test_apt_failure_aborts_pre_handoff_old_regime_intact
run_test test_hold_failure_aborts_pre_handoff
run_test test_unmask_failure_aborts_pre_handoff
run_test test_pre_handoff_disable_cleanup_failure_is_reported
run_test test_pre_handoff_unmask_cleanup_failure_is_reported
run_test test_service_refusing_start_aborts_pre_handoff
run_test test_armed_restart_failure_restores_last_known_good
run_test test_armed_missing_prior_config_falls_back_to_stock_oomd
run_test test_armed_snapshot_restore_install_failure_falls_back_to_stock_oomd
run_test test_armed_successful_replacement_cleans_snapshot
run_test test_armed_unrevivable_restores_stock_oomd
run_test test_armed_recovery_rejects_malformed_config
run_test test_armed_version_assert_failure_lands_in_stock_oomd
run_test test_armed_unrevivable_verifies_stock_pressure_before_disable
run_test test_armed_stock_pressure_verification_failure_never_disables_earlyoom
run_test test_rollback_restores_stock_pressure_before_disabling_earlyoom
run_test test_rollback_succeeds_with_inactive_user_manager
run_test test_rollback_reload_failure_leaves_earlyoom_active
run_test test_rollback_inactive_reload_failure_keeps_emergency_responder
run_test test_rollback_inactive_success_restores_final_state_before_disable
run_test test_rollback_inactive_query_failure_keeps_emergency_responder
run_test test_rollback_reports_failed_emergency_reactivation_honestly
run_test test_rollback_inactive_oomd_start_failure_keeps_emergency_config
run_test test_rollback_inactive_oomd_active_failure_keeps_emergency_config
run_test test_rollback_inactive_dropin_remove_failure_keeps_emergency_responder
run_test test_rollback_retries_reload_after_reload_failure_removed_dropins
run_test test_rollback_pressure_verify_failure_leaves_earlyoom_active
run_test test_rollback_is_idempotent
run_test test_rollback_with_inactive_user_manager_is_idempotent

[ "$test_count" -gt 0 ] || fail "DEVBOX_TEST_ONLY did not match a test: ${DEVBOX_TEST_ONLY:-}"

echo "devbox-memory-hotfix tests passed"
