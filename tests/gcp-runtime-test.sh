#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="$ROOT_DIR/gcp/runtime.tf"
VARIABLES="$ROOT_DIR/gcp/variables.tf"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { rg -q --fixed-strings "$1" "$RUNTIME" || fail "expected gcp/runtime.tf to contain: $1"; }
assert_resource_contains() {
  local resource_name="$1"
  local expected="$2"
  local resource_block

  resource_block="$(
    awk -v header="resource \"google_storage_bucket_object\" \"$resource_name\"" '
      index($0, header) { in_resource = 1 }
      in_resource {
        print
        opens = gsub(/{/, "{")
        closes = gsub(/}/, "}")
        depth += opens - closes
        if (depth == 0) exit
      }
    ' "$RUNTIME"
  )"

  [ -n "$resource_block" ] || fail "google_storage_bucket_object.$resource_name missing"
  grep -Fq "$expected" <<<"$resource_block" ||
    fail "expected google_storage_bucket_object.$resource_name to contain: $expected"
}

[ -f "$RUNTIME" ] || fail "gcp/runtime.tf missing"

# Content-addressed layout.
assert_contains 'runtime/${each.key}/${local.devbox_runtime_script_sha256[each.key]}'
assert_contains 'runtime/manifest/${local.runtime_manifest_sha256}.json'

# Terraform replacement must retain old content-addressed objects because the
# promoted manifest can continue to reference them during candidate rollout.
assert_resource_contains 'devbox_runtime_script' 'deletion_policy = "ABANDON"'
assert_resource_contains 'runtime_manifest_candidate' 'deletion_policy = "ABANDON"'

# terraform apply must NEVER manage the fleet pointer.
if rg -q '"runtime/manifest\.json"' "$RUNTIME"; then
  fail "gcp/runtime.tf must not manage runtime/manifest.json — promotion only (scripts/gcp/promote-runtime.sh)"
fi

# The 5 bundle scripts, GCP variants + shared.
for s in devbox-converge devbox-memory-hotfix devbox-toolchain devbox-observability devbox-bedrock-config; do
  rg -q --fixed-strings "\"$s\"" "$RUNTIME" || fail "bundle must include $s"
done
assert_contains 'scripts/gcp/devbox-converge'
assert_contains 'scripts/devbox-memory-hotfix'

# devbox-aws-creds ships in the bundle too (installed, not dispatched).
assert_contains 'devbox-aws-creds'

# Bucket hygiene + read-only instance access.
assert_contains 'uniform_bucket_level_access = true'
assert_contains 'roles/storage.objectViewer'

# Bedrock keys must be optional (absent → concern no-op).
assert_contains 'var.bedrock_role_arn == ""'

# VS Code is installed only by the new-machine toolchain gate, but its
# latest-at-create policy is delivered through the GCP runtime manifest.
assert_contains 'DEVBOX_VSCODE_VERSION'
assert_contains 'var.toolchain.vscode_version'

# earlyoom knobs ride the manifest env; the dead pressure knobs must not.
assert_contains 'DEVBOX_EARLYOOM_MEM_PCT'
assert_contains 'DEVBOX_EARLYOOM_SWAP_PCT'
assert_contains 'DEVBOX_EARLYOOM_AVOID_REGEX'
assert_contains 'DEVBOX_EARLYOOM_ENABLED'

# Org MCP connectors ride the manifest as JSON (default {} — step skipped).
assert_contains 'DEVBOX_CODEX_MCP_CONNECTORS'
assert_contains 'jsonencode(var.codex_mcp_connectors)'

if rg -q 'DEVBOX_OOMD_PRESSURE_LIMIT|DEVBOX_OOMD_PRESSURE_DURATION' "$RUNTIME"; then
  fail "oomd pressure env keys were removed by the earlyoom design; must not be in the manifest"
fi

[ -f "$VARIABLES" ] || fail "gcp/variables.tf missing"
for expected_pin in \
  'ANTHROPIC_MODEL[[:space:]]*=[[:space:]]*"anthropic\.claude-fable-5\[1m\]"' \
  'ANTHROPIC_DEFAULT_FABLE_MODEL[[:space:]]*=[[:space:]]*"global\.anthropic\.claude-fable-5\[1m\]"' \
  'ANTHROPIC_DEFAULT_OPUS_MODEL[[:space:]]*=[[:space:]]*"global\.anthropic\.claude-opus-5\[1m\]"'; do
  rg -q "$expected_pin" "$VARIABLES" \
    || fail "Claude Bedrock Fable and Opus pins must request 1M context"
done
for expected_picker_model in \
  'anthropic\.claude-fable-5\[1m\]' \
  'global\.anthropic\.claude-fable-5\[1m\]' \
  'global\.anthropic\.claude-opus-5\[1m\]'; do
  rg -q "^[[:space:]]*\"${expected_picker_model}\",[[:space:]]*$" "$VARIABLES" \
    || fail "Claude Bedrock picker must include the 1M model ${expected_picker_model}"
  [ "$(rg -c "^[[:space:]]*\"${expected_picker_model}\",[[:space:]]*$" "$VARIABLES")" -eq 1 ] \
    || fail "Claude Bedrock picker must contain exactly one ${expected_picker_model} entry"
done
bedrock_available_models_default="$(
  awk '
    /^variable "bedrock_available_models"/ { in_picker = 1 }
    in_picker { print }
    in_picker && /^}/ { exit }
  ' "$VARIABLES"
)"
other_opus_picker_entries="$(
  printf '%s\n' "$bedrock_available_models_default" \
    | rg '^[[:space:]]*"[^"]*claude-opus[^"]*",?[[:space:]]*$' \
    | rg -v '^[[:space:]]*"global\.anthropic\.claude-opus-5\[1m\]",[[:space:]]*$' \
    || true
)"
[ -z "$other_opus_picker_entries" ] \
  || fail "Claude Bedrock picker must contain no Opus entry other than global.anthropic.claude-opus-5[1m]"
if rg -q 'claude-opus-4-8' "$VARIABLES"; then
  fail "active GCP fleet defaults must not retain Claude Opus 4.8"
fi

echo "PASS: gcp-runtime-test"
