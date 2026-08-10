# Contributing

Contributions welcome — especially fixes from people actually running a
fleet.

## Before you open a PR

Run the full static suite (no cloud access needed):

    for t in tests/*.sh; do bash "$t" || exit 1; done

And the Terraform checks:

    terraform -chdir=gcp init -backend=false -lockfile=readonly
    terraform -chdir=gcp fmt -check -recursive && terraform -chdir=gcp validate && terraform -chdir=gcp test

CI runs exactly these on every PR.

## Ground rules

- Behavior changes come with a matching test in `tests/`.
- Never commit `terraform.tfvars`, `gcp/backend.hcl`, or
  `scripts/devbox-repos.default` — they hold org secrets/config and are
  gitignored on purpose.
- Keep the safety-critical admin flows intact (ACL ownership gate,
  generation-keeper rebuilds, promote-only rollouts). If a change touches
  one, say so explicitly in the PR description.
- Using an AI agent to contribute? Point it at `AGENTS.md` first.
