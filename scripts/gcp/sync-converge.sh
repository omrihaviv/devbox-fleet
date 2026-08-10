#!/usr/bin/env bash
# Trigger devbox-converge on GCP machines over Tailscale SSH.
# No SSM, no DEVBOX_* env exports — the manifest carries fleet config.
# Canary a candidate with --manifest-sha before promoting it.
set -euo pipefail

usage() {
  echo "usage: $0 <machine> [<machine> ...] [--manifest-sha <sha256>] [--allow-tailscale-upgrade]" >&2
  exit 2
}

machines=()
converge_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest-sha)
      [ -n "${2:-}" ] || usage
      converge_args+=(--manifest-sha "$2"); shift 2 ;;
    --allow-tailscale-upgrade)
      converge_args+=(--allow-tailscale-upgrade); shift ;;
    -*) usage ;;
    *) machines+=("$1"); shift ;;
  esac
done
[ "${#machines[@]}" -ge 1 ] || usage

rc=0
for machine in "${machines[@]}"; do
  echo "=== ${machine}-devbox ==="
  # Direct invocation (not `systemctl start`) so output streams back live.
  # The converge flock prevents overlap with a timer-started run.
  # Client-side expansion of converge_args is intended (built here, sent remote).
  # shellcheck disable=SC2029
  if ! ssh "dev@${machine}-devbox" "sudo /usr/local/bin/devbox-converge ${converge_args[*]:-}"; then
    echo "ERROR: converge failed on ${machine}-devbox" >&2
    rc=1
  fi
done
exit $rc
