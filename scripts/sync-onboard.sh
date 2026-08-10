#!/bin/bash
# Push devbox-onboard (+ devbox-repos.default when present) to running devboxes.
#
# CRITICAL — what is and is NOT synced here:
#   - devbox-onboard           SYNCED  (idempotent shell, low blast radius)
#   - devbox-repos.default     SYNCED when present  (data file, low blast radius)
#   - chrome-devtools-mcp-wrapper.sh           NOT SYNCED  (see below)
#   - chrome-devtools-mcp-steered-wrapper.sh   NOT SYNCED  (see below)
#       Both wrappers are root-owned, security-relevant launchers whose hashes
#       are in random_uuid.devbox_generation keepers. Bypassing the keeper path
#       would let a wrapper edit change the Chrome launch surface (executable
#       path, --headless mode, --user-data-dir, --browser-url target, extra
#       flags) on running boxes without a Terraform plan/review/audit and
#       without rotating the Tailscale auth key. Wrapper changes MUST go
#       through a keeper bump → terraform apply → fresh-bootstrap validation.
#       See admin-runbook.md "Rebuild a box".
#
# Usage: scripts/sync-onboard.sh [dev-name ...]
#   With no args, pushes to every machine in the gcp/ root's state.
#   With dev names, pushes only to those.
#
# Requires:
#   - SSH access to <dev>-devbox via Tailscale (i.e. admin tailnet identity)
#   - sudo on the box (admin uses tailnet identity dev; sudo is passwordless)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

push_one() {
  local dev="$1"
  echo "==> $dev-devbox"

  local files=("$REPO_ROOT/scripts/devbox-onboard")
  local push_repos=0
  if [ -f "$REPO_ROOT/scripts/devbox-repos.default" ]; then
    files+=("$REPO_ROOT/scripts/devbox-repos.default")
    push_repos=1
  fi

  scp "${files[@]}" "dev@${dev}-devbox:/tmp/"

  local repo_install=""
  if [ "$push_repos" -eq 1 ]; then
    repo_install="sudo install -o root -g root -m 0644 /tmp/devbox-repos.default /etc/devbox-repos.default && rm -f /tmp/devbox-repos.default"
  fi
  ssh "dev@${dev}-devbox" "
    set -euo pipefail
    sudo install -o root -g root -m 0755 /tmp/devbox-onboard /usr/local/bin/devbox-onboard
    rm -f /tmp/devbox-onboard
    ${repo_install}
    echo '  ✓ pushed'
  "
}

if [ "$#" -eq 0 ]; then
  # Machine keys from the GCP root's state.
  devs=$(terraform -chdir="$REPO_ROOT/gcp" output -json devbox_hostnames | jq -r 'keys[]')
else
  devs="$*"
fi

for d in $devs; do
  push_one "$d"
done
