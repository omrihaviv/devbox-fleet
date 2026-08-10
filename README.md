# devbox-fleet

Per-developer cloud devboxes on GCP — one or more machines per person,
normally reached via Tailscale SSH, with IAP as admin breakglass. No public
application/TCP ingress, persistent per-dev data disks, automated onboarding,
and a converged runtime keep the fleet consistent without rebuilds.

## What you get

- **Terraform root (`gcp/`)** — instances, per-dev persistent data disks,
  daily snapshots, a VPC with no public application ingress (Tailscale
  WireGuard UDP 41641 + IAP breakglass only), Cloud Monitoring alerts, and the
  tailnet ACL — rendered per dev: each dev reaches only their own machines, as
  user `dev` (admins
  reach every box; all tailnet members reach preview ports 3000/3005 — see the
  security baseline in `docs/admin-runbook.md`).
- **Runtime convergence** — toolchain, memory guardrails (earlyoom), and
  optional Bedrock config ride a content-addressed manifest in GCS.
  `terraform apply` only uploads candidates; boxes move when you run
  `scripts/gcp/promote-runtime.sh` after a canary. Rollback = promote the
  previous manifest. Values explicitly set to `latest` are the documented
  exception: they resolve a signed apt-repository candidate on each converge
  and are **not promotion-gated**. Mirror and pin those packages if you require
  byte-for-byte reproducibility.
- **Dev onboarding** — first SSH login walks each dev through GitHub auth,
  Claude Code auth, Chrome DevTools MCP, org-configured Codex MCP
  connectors, and cloning your org's repo list.
- **Optional AWS Bedrock access (`aws-federation/`)** — the boxes' GCP
  service account federates into one AWS role via workload identity; no AWS
  keys on any box.

## Quick start (admin)

1. One-time Tailscale tag/OAuth setup and GCP bootstrap:
   `docs/admin-runbook.md`.
2. Configure:
   ```bash
   cd gcp
   cp backend.hcl.example backend.hcl            # your tfstate bucket
   cp terraform.tfvars.example terraform.tfvars  # your org values
   cp ../scripts/devbox-repos.example ../scripts/devbox-repos.default  # optional
   terraform init -backend-config=backend.hcl
   ```
   The repo list is optional, but write it **before the first apply**: it is
   baked into each box's boot config, and a dev's `~/.devbox-repos` is seeded
   from it once, at their first login. A dev who onboards before the list
   exists gets an empty one that is never re-seeded.
3. First apply with the ACL gate **closed** (`manage_tailscale_acl = false`,
   `devs = {}`). Promote the initial runtime before any box exists, then inspect
   the gate-closed ACL skeleton:
   ```bash
   terraform apply
   DEVBOX_RUNTIME_BUCKET=$(terraform output -raw runtime_bucket) \
     ../scripts/gcp/promote-runtime.sh $(terraform output -raw runtime_manifest_sha256)
   terraform output -raw devbox_acl_json
   ```
   > **Warning:** once you flip `manage_tailscale_acl = true`, this root
   > becomes the **sole writer** of your tailnet ACL and replaces the whole
   > policy document on every apply. It is designed for a tailnet dedicated
   > to devboxes — merge any other policy you need into
   > `gcp/tailscale-acl.tf` first.
4. Flip the gate and add your first machine together. Follow the runbook to
   inspect the **planned** final ACL, apply that exact saved plan, and walk the
   first-machine canary checklist.

Devs: see `docs/dev-quickstart.md`.

## Tests

`bash tests/<name>.sh` — static suite, no cloud access needed. It targets a
GNU/Linux environment with Bash, Git, GNU core utilities, `rg`, `jq`, and
Python 3.11+ (`tomllib`). For the Terraform checks without a backend:
`terraform init -backend=false` then `terraform validate` / `terraform test`
in `gcp/`.

## License

MIT — see `LICENSE`.
