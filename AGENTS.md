# Agent instructions for devbox-fleet

Instructions for AI coding agents working in this repository. Humans: see
`README.md` and `docs/`.

## What this repo is

Terraform + convergence scripts for a small fleet of per-developer cloud
devboxes on GCP, reachable over Tailscale. `gcp/` is the Terraform root that
provisions everything; `aws-federation/` is an optional root for AWS Bedrock
access; `scripts/` holds runtime-convergence and onboarding scripts delivered
to boxes; `tests/` is a static, no-cloud test suite; `docs/` holds the
runbook, quickstarts, and setup playbook.

## Running tests

The suite is static — no cloud access, no credentials:

    for t in tests/*.sh; do bash "$t" || exit 1; done

Requirements: GNU/Linux, Bash, Git, GNU coreutils, `rg`, `jq`, Python 3.11+.

Terraform checks without a backend:

    terraform -chdir=gcp init -backend=false -lockfile=readonly
    terraform -chdir=gcp validate
    terraform -chdir=gcp test
    terraform -chdir=aws-federation init -backend=false -lockfile=readonly
    terraform -chdir=aws-federation validate

## Conventions

- Bash scripts use `set -euo pipefail`; tests define `fail()` and
  `assert_contains()` (rg `--fixed-strings`) and end with
  `echo "PASS: <test-name>"`.
- Behavior changes come with a matching change in `tests/`.
- Tests assert on doc/config content deliberately (e.g. README must contain
  the fixed string `not promotion-gated`). If a content edit fails a test,
  the test is telling you the content is load-bearing — keep the phrase or
  escalate; do not delete the assertion to make it pass.

## Guardrails — do NOT "fix" these

- `gcp/terraform.tfvars`, `gcp/backend.hcl`, and
  `scripts/devbox-repos.default` are gitignored because they hold org
  secrets/config. Never commit them, never inline their contents into
  committed files.
- This root is the **sole writer of the tailnet ACL** once
  `manage_tailscale_acl = true`. That is a designed invariant, not a bug.
- `devs` must be `{}` while the gate is closed — enforced by validation in
  `gcp/variables.tf`.
- Rebuilds happen ONLY via the generation-keeper path (see
  `docs/admin-runbook.md`); never suggest `terraform apply -replace=` on an
  instance.
- Only `scripts/gcp/promote-runtime.sh` writes the runtime pointer;
  `terraform apply` uploading a candidate manifest is not a rollout.
- `docs/admin-runbook.md` is authoritative for admin flows; quickstarts are
  condensed views of it.

## Setting the fleet up for a user

Follow the playbook in `docs/setup-agent.md`. Its rules (mutation approval
gate, secrets never in chat) override any shortcut you are tempted to take.
