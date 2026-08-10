#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT_DIR/aws-federation/main.tf"
PROVIDERS="$ROOT_DIR/aws-federation/providers.tf"
VARIABLES="$ROOT_DIR/aws-federation/variables.tf"
RUNBOOK="$ROOT_DIR/docs/admin-runbook.md"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { rg -q --fixed-strings "$1" "$MAIN" || fail "expected aws-federation/main.tf to contain: $1"; }
assert_file_contains() { rg -q --fixed-strings "$2" "$1" || fail "expected $1 to contain: $2"; }

[ -f "$MAIN" ] || fail "aws-federation/main.tf missing"
[ -f "$RUNBOOK" ] || fail "docs/admin-runbook.md missing"

# Google is BUILT INTO AWS web-identity federation: creating an IAM OIDC
# provider for accounts.google.com is explicitly wrong (design review
# finding 1). Only Principal.Federated is allowed. Match the QUOTED
# resource/data declaration form so this guard fires only when a provider
# block is actually declared — not when main.tf's rationale comment merely
# names the resource type to explain why it is deliberately absent.
if rg -q '"aws_iam_openid_connect_provider"' "$ROOT_DIR/aws-federation"/*.tf; then
  fail "must NOT create an IAM OIDC provider for Google — use Principal.Federated = accounts.google.com"
fi
assert_contains '"accounts.google.com"'

# Trust conditions: sub + aud pin the SA numeric ID; oaud pins the dedicated
# audience.
assert_contains 'accounts.google.com:sub'
assert_contains 'accounts.google.com:aud'
assert_contains 'accounts.google.com:oaud'
assert_file_contains "$VARIABLES" 'default     = "devbox-fleet-aws-federation"'

# devbox-* naming keeps everything inside a devbox-*-scoped deployer policy.
assert_contains 'devbox-gcp-workload'
assert_file_contains "$VARIABLES" 'default     = "devbox-fleet"'
assert_file_contains "$PROVIDERS" 'Project   = var.project_tag'

# Initial grant: Bedrock invocation only.
assert_contains 'bedrock:InvokeModel'
assert_contains 'bedrock:InvokeModelWithResponseStream'

# The optional federation path must be runnable from a fresh public clone and
# must call out its local-state durability contract.
assert_file_contains "$RUNBOOK" 'cp aws-federation/terraform.tfvars.example aws-federation/terraform.tfvars'
assert_file_contains "$RUNBOOK" 'aws sts get-caller-identity'
assert_file_contains "$RUNBOOK" 'terraform -chdir=aws-federation init'
assert_file_contains "$RUNBOOK" 'local state'

echo "PASS: aws-federation-test"
