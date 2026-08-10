#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIABLES="$ROOT_DIR/gcp/variables.tf"
LOCALS="$ROOT_DIR/gcp/locals.tf"
VERSIONS="$ROOT_DIR/gcp/versions.tf"
EXAMPLE="$ROOT_DIR/gcp/terraform.tfvars.example"
README="$ROOT_DIR/README.md"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local pattern="$1" file="$2"
  rg -q --fixed-strings "$pattern" "$file" \
    || fail "expected $file to contain: $pattern"
}

assert_not_contains() {
  local pattern="$1" file="$2"
  if rg -q --fixed-strings "$pattern" "$file"; then
    fail "expected $file to NOT contain: $pattern"
  fi
}

[ -f "$VARIABLES" ] || fail "gcp/variables.tf missing"
[ -f "$LOCALS" ] || fail "gcp/locals.tf missing"
[ -f "$VERSIONS" ] || fail "gcp/versions.tf missing"
[ -f "$EXAMPLE" ] || fail "gcp/terraform.tfvars.example missing"
[ -f "$README" ] || fail "README.md missing"

# Terraform floor: cross-variable validation requires >= 1.9.
assert_contains 'required_version = ">= 1.9.0"' "$VERSIONS"
assert_contains 'backend "gcs"' "$VERSIONS"

# The ACL ownership gate must default CLOSED.
assert_contains 'variable "manage_tailscale_acl"' "$VARIABLES"
assert_contains 'default     = false' "$VARIABLES"
# devs must be rejected while the gate is closed (cross-variable validation).
assert_contains 'var.manage_tailscale_acl || length(var.devs) == 0' "$VARIABLES"

# Spec defaults.
assert_contains 'default     = "us-central1"' "$VARIABLES"
assert_contains 'default     = "n2-standard-4"' "$VARIABLES"
assert_contains 'variable "root_disk_gb"' "$VARIABLES"
assert_contains 'default     = 120' "$VARIABLES"
assert_contains 'default     = 64' "$VARIABLES"
assert_contains 'root_disk_gb = optional(number)' "$VARIABLES"
assert_contains 'root_disk_gb    = coalesce(m.root_disk_gb, var.root_disk_gb)' "$LOCALS"
assert_contains 'startswith(m.zone, "${var.gcp_region}-")' "$VARIABLES"

# Pinned image, never family-latest.
assert_contains 'ubuntu-2404-noble-amd64-v' "$VARIABLES"
assert_not_contains 'google_compute_image' "$VARIABLES"

# ARM families rejected (image is amd64).
assert_contains 't2a|c4a|n4a' "$VARIABLES"

# Flatten preserves the primary-collapses rule + collision guard.
assert_contains 'mname == "primary" ? uname : "${uname}-${mname}"' "$LOCALS"
assert_contains 'mname == "primary" ? uname : "${uname}-${mname}"' "$VARIABLES"

# external_machines must reject keys colliding with flattened dev keys.
assert_contains 'variable "external_machines"' "$VARIABLES"

# VS Code's latest-at-create default must not force existing callers of the
# shared toolchain object to provide a new field.
rg -q 'vscode_version[[:space:]]*=[[:space:]]*optional\(string, "latest"\)' "$VARIABLES" \
  || fail "vscode_version must default to optional(string, \"latest\")"
assert_contains '^[0-9a-fA-F]{64}$' "$VARIABLES"

# The two federation roots must default to the same dedicated audience.
assert_contains 'default     = "devbox-fleet-aws-federation"' "$VARIABLES"

# The committed example must be runnable after org values are filled: immutable
# public installer hashes are real values, not first-boot failure placeholders.
assert_not_contains 'REPLACE_WITH_REAL_SHA' "$EXAMPLE"
rg -q 'nvm_install_sha256[[:space:]]*=[[:space:]]*"[0-9a-f]{64}"' "$EXAMPLE" \
  || fail "example nvm_install_sha256 must be a complete lowercase SHA-256"
rg -q 'aws_cli_install_sha256[[:space:]]*=[[:space:]]*"[0-9a-f]{64}"' "$EXAMPLE" \
  || fail "example aws_cli_install_sha256 must be a complete lowercase SHA-256"

# Upstreams that evict old apt packages deliberately use `latest`; make the
# reproducibility/canary exception impossible to miss in config and overview.
assert_contains 'not promotion-gated' "$EXAMPLE"
assert_contains 'not promotion-gated' "$README"
assert_contains 'pinned or deliberately floating' "$VARIABLES"

# earlyoom rollout (2026-07-23): pressure knobs removed (dead config),
# earlyoom knobs added. Swap backstop knob stays.
assert_contains 'variable "earlyoom_mem_pct"' "$VARIABLES"
assert_contains 'variable "earlyoom_swap_pct"' "$VARIABLES"
assert_contains 'variable "earlyoom_avoid_regex"' "$VARIABLES"
assert_contains 'variable "earlyoom_enabled"' "$VARIABLES"
assert_contains 'variable "oomd_swap_used_limit"' "$VARIABLES"
assert_not_contains 'oomd_memory_pressure_limit' "$VARIABLES"
assert_not_contains 'oomd_memory_pressure_duration_sec' "$VARIABLES"

# tmux plugins (2026-07-24): commit pins default in variables.tf (optional →
# no tfvars edit) and ride the manifest env to devbox-toolchain.
RUNTIME="$ROOT_DIR/gcp/runtime.tf"
[ -f "$RUNTIME" ] || fail "gcp/runtime.tf missing"
rg -q 'tmux_resurrect_commit[[:space:]]*=[[:space:]]*optional\(string, "[0-9a-f]{40}"\)' "$VARIABLES" \
  || fail "tmux_resurrect_commit must default to an optional 40-hex commit pin"
rg -q 'tmux_continuum_commit[[:space:]]*=[[:space:]]*optional\(string, "[0-9a-f]{40}"\)' "$VARIABLES" \
  || fail "tmux_continuum_commit must default to an optional 40-hex commit pin"
assert_contains 'DEVBOX_TMUX_RESURRECT_COMMIT       = var.toolchain.tmux_resurrect_commit' "$RUNTIME"
assert_contains 'DEVBOX_TMUX_CONTINUUM_COMMIT       = var.toolchain.tmux_continuum_commit' "$RUNTIME"

echo "PASS: gcp-variables-test"
