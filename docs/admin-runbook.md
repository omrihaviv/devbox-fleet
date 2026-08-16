# Devbox admin runbook

Everything an admin does with the fleet: one-time Tailscale and GCP bootstrap,
the first apply (including the tailnet-ACL ownership gate), routine
operations, offboarding, breakglass, and the quarterly restore drill.

First time? Start with the condensed [admin quickstart](admin-quickstart.md);
this runbook is the complete reference and the authority when they differ.

**Converge:** each box re-applies the promoted runtime config on its own timer
— roughly every 8 hours, plus up to 1 hour of jitter, so a change reaches the
whole fleet within ~9 hours. **Promote:** moving the fleet-wide pointer to a
new runtime manifest — only `scripts/gcp/promote-runtime.sh` does this;
`terraform apply` just uploads candidates, so a converge timer that fires
mid-canary keeps consuming the last promoted config.

The Terraform root (`gcp/`) provisions every machine and is the **sole owner of
the tailnet ACL** — the document it renders covers the machines in `var.devs`
plus anything listed in `var.external_machines` (machines managed outside
this root that must keep tailnet access; empty for a fresh fleet). Devs reach
their boxes as `ssh dev@<key>-devbox`.

Terraform state lives in the versioned GCS bucket named in `gcp/backend.hcl`;
Terraform authenticates with admin ADC (Application Default Credentials).

**Contents**

- [One-time Tailscale setup](#one-time-tailscale-setup)
- [One-time GCP bootstrap](#one-time-gcp-bootstrap)
- [First apply](#first-apply)
- [Routine operations](#routine-operations)
- [Day-2 changes to `devbox-onboard` (no rebuild)](#day-2-changes-to-devbox-onboard-no-rebuild)
- [Admin SSH and the dev's tmux](#admin-ssh-and-the-devs-tmux)
- [Steerable Chrome health](#steerable-chrome-health)
- [Offboarding (integrity-first)](#offboarding-integrity-first)
- [Breakglass (reserved for when Tailscale is down)](#breakglass-reserved-for-when-tailscale-is-down)
- [Quarterly restore drill](#quarterly-restore-drill)

## One-time Tailscale setup

1. **Tailnet.** Create a tailnet at https://login.tailscale.com/, invite your
   admin email, accept the invite. The free Personal plan covers up to six
   users.

   **IMPORTANT — ACL ownership.** This root owns the *entire* tailnet ACL
   document via `tailscale_acl.devbox` with `overwrite_existing_content = true`.
   Every `terraform apply` replaces whatever policy is configured in the admin
   panel. Use a tailnet dedicated to devboxes, or merge your other policy into
   `gcp/tailscale-acl.tf` before you open the gate (see "First apply"). The
   rendered rules grant each dev access to every machine they own (one tag per
   machine, `tag:devbox-<machine-key>`) and grant `group:devbox-admins` access
   to every box.

2. **Seed the delegating tag before creating the OAuth client.** Tailscale only
   lets an `auth_keys` OAuth client select tags that already exist in the
   tailnet policy. In the admin panel's Access controls editor, merge this entry
   into the existing `tagOwners` object and save the policy:

   ```json
   "tagOwners": {
     "tag:devbox-key-minter": ["autogroup:admin"]
   }
   ```

   If `tagOwners` already exists, add only the entry inside it. Preserve every
   other rule: this is a minimal bootstrap seed, not the Terraform takeover.
   The order is required by Tailscale's
   [delegated-tag OAuth flow](https://tailscale.com/docs/features/oauth-clients#generating-long-lived-auth-keys).
   Terraform replaces this seed with the complete reviewed document during the
   first-machine apply below.

3. **OAuth client.** Admin panel → Trust credentials → Credential → OAuth →
   create ONE client
   with BOTH scopes (the same provider mints auth keys AND owns the policy
   document):
   - `auth_keys` (write), tag-restricted to `tag:devbox-key-minter` — for
     `tailscale_tailnet_key.devbox`
   - `policy_file` (write) — for `tailscale_acl.devbox`

   Keep the client id and secret in your admin credential store for now —
   `gcp/terraform.tfvars` does not exist yet, and the "First apply" step's
   `cp` from the example would overwrite anything saved there earlier. You
   fill `tailscale_oauth_client_id` / `tailscale_oauth_client_secret` and
   your tailnet name (`tailscale_tailnet`) right after that `cp`.

   **Why a single tag, not `tag:devbox-*`.** Tailscale OAuth clients do NOT
   support tag wildcards — `tag:devbox-*` is not a valid scope. Authorization
   works through a delegating-tag pattern: the OAuth client owns one tag,
   `tag:devbox-key-minter`, and `gcp/tailscale-acl.tf` sets `tagOwners` so each
   per-machine tag `tag:devbox-<machine-key>` is owned by
   `tag:devbox-key-minter`, which is in turn owned by `autogroup:admin` and
   itself. The client can then mint a key carrying `tag:devbox-<machine-key>`
   because its own tag transitively owns the requested tag. Full rationale in
   `gcp/providers.tf`.

   **Trust note:** this single credential can rewrite your tailnet ACL. Treat
   it like an admin credential — keep it where you keep your cloud admin
   credentials and never share it with devs. `gcp/terraform.tfvars` is
   gitignored precisely because it holds this secret; never force-add it.

## One-time GCP bootstrap

Run once, before the first `terraform -chdir=gcp apply`. Substitute your own
project id, org and billing ids, and region. The admin-group owner binding is
done here by hand — deliberately NOT in Terraform (see the comment in
`gcp/iam.tf`): the root grants explicit breakglass roles, but the
`roles/owner` bootstrap must not be self-managed.

gcloud keeps two separate credentials: the CLI's own login (used by every
`gcloud` command below) and Application Default Credentials (ADC — used by
Terraform; the block's last line). A fresh machine needs both, and the CLI
login must come first or the mutating commands below fail with "no active
account".

```bash
gcloud auth list    # CLI credential — skip the next line if your admin account is already active
gcloud auth login
gcloud projects create your-project-id --organization=<ORG_ID>
gcloud billing projects link your-project-id --billing-account=<BILLING_ACCOUNT>
gcloud services enable compute.googleapis.com iam.googleapis.com iap.googleapis.com \
  storage.googleapis.com monitoring.googleapis.com logging.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=your-project-id
# Terraform state bucket — versioned, uniform access.
gcloud storage buckets create gs://your-tfstate-bucket --project=your-project-id \
  --location=us-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://your-tfstate-bucket --versioning
cp gcp/backend.hcl.example gcp/backend.hcl   # set bucket = your bucket
# Admin group: owner via bootstrap (NOT Terraform — see gcp/iam.tf comment).
gcloud projects add-iam-policy-binding your-project-id \
  --member="group:devbox-admins@example.com" --role="roles/owner"
gcloud auth application-default login   # Terraform ADC
```

Initialize the root against that backend:

```bash
terraform -chdir=gcp init -backend-config=backend.hcl
```

### Repo list — write it BEFORE the first apply

`scripts/devbox-repos.example` is the committed template; the real list lives at
`scripts/devbox-repos.default`, which is gitignored:

```bash
cp scripts/devbox-repos.example scripts/devbox-repos.default   # then list your org's repos
```

The list is optional, but write it before the first apply. Its content is baked
into each box's boot config as `/etc/devbox-repos.default`, and `devbox-onboard`
seeds a dev's `~/.devbox-repos` from it **once**, at their first login. With no
list, that seed value is empty: the dev gets a blank `~/.devbox-repos` that is
never re-seeded, and onboarding clones nothing. Recovery for a dev already in
that state is dev-side — they edit `~/.devbox-repos` and re-run
`devbox-onboard` (it prompts, then re-runs; the clone step is idempotent).
Adding the list later also needs `scripts/sync-onboard.sh` to reach existing
boxes (see "Day-2 changes to `devbox-onboard`").

## First apply

This root will own your tailnet's ACL. Walk the steps in order and **do not
flip the gate before you have looked at the preview**.

**1. Plumbing-only apply (gate CLOSED).**

```bash
cp gcp/terraform.tfvars.example gcp/terraform.tfvars
# Fill in: gcp_project_id, tailscale_oauth_*, tailscale_tailnet, admin emails.
# Keep the gate closed and no machines:
#   devs                 = {}
#   manage_tailscale_acl = false
terraform -chdir=gcp init -backend-config=backend.hcl
terraform -chdir=gcp apply
```

Verify the plan contains **no `tailscale_acl` resource and no
`google_compute_instance`** — plumbing only (bucket, SA + IAM, network,
monitoring, runtime candidate upload). Then do the initial runtime
promotion — risk-free because no boxes exist yet:

```bash
DEVBOX_RUNTIME_BUCKET=$(terraform -chdir=gcp output -raw runtime_bucket) \
  scripts/gcp/promote-runtime.sh $(terraform -chdir=gcp output -raw runtime_manifest_sha256)
```

**2. Inspect the gate-closed ACL skeleton.**

```bash
terraform -chdir=gcp output -raw devbox_acl_json | jq .
```

**The eventual document REPLACES your tailnet's entire ACL when the gate opens.**
If your tailnet carries policy beyond devboxes, merge it into
`gcp/tailscale-acl.tf` and re-preview until the rendered document is the
policy you want. Machines managed outside this root that must keep access
go in `external_machines`.

While the gate is closed, `devs` is forced to `{}` (`gcp/variables.tf` rejects
anything else — a machine cannot join the tailnet before its tag-owner
declaration exists). This output is therefore a **SKELETON**: admin group, the
`tag:devbox-key-minter` tag owner, the admin-self rule, and node attributes,
with no per-machine rules. Read it for the shape of what Terraform will
replace, not as the final policy.

**3. Preview the exact first policy, then apply that same plan.** In
`gcp/terraform.tfvars`, set `manage_tailscale_acl = true` and add your own first
machine to `devs`. Create a fresh saved plan outside the repo, extract the
planned ACL output, and inspect every group, owner, packet rule, SSH rule, node
attribute, and test before applying:

```bash
set -euo pipefail
first_plan_dir="$(mktemp -d)"
first_plan="$first_plan_dir/first-machine.tfplan"
terraform -chdir=gcp plan -out="$first_plan"
terraform -chdir=gcp show -json "$first_plan" \
  | jq -er '.planned_values.outputs.devbox_acl_json.value | select(type == "string" and length > 0)' \
  | jq -e .
# STOP if this is not the complete policy you intend to own.
```

Applying a saved plan does not prompt for confirmation. Stop here and read
the printed document; run the apply only when it is exactly the policy you
intend to own:

```bash
terraform -chdir=gcp apply "$first_plan"
rm -f -- "$first_plan" && rmdir -- "$first_plan_dir"
```

If you stop before apply, delete the saved plan: it contains evaluated
sensitive variables. Applying the exact reviewed file prevents configuration
edits or a refreshed plan from changing the policy between preview and apply.
From this apply onward the root is the sole ACL writer — never flip the gate
back.

### Step 4 — First-apply canary checklist

After the exact-plan apply above, walk this checklist on the new box (`<name>`
is the machine key):

- **Tailscale SSH:** `ssh dev@<name>-devbox true` connects.
- **Data disk mounted:** `ssh dev@<name>-devbox 'mount | grep /data'` shows `/dev/disk/by-id/google-data` on `/data`.
- **Converge timer armed:** `ssh dev@<name>-devbox 'systemctl list-timers devbox-converge.timer'` shows a next-run within ~9h (the 8h `OnCalendar` schedule plus up to 1h of `RandomizedDelaySec`).
- **First heartbeat AND the metric incremented (do not skip the metric check):** in Cloud Logging, the boot-time converge emits a log line matching `resource.type="gce_instance" AND (textPayload:"devbox-converge-success" OR jsonPayload.message:"devbox-converge-success")`. Then confirm the **log-based metric actually incremented** in Metrics Explorer under `logging.googleapis.com/user/devbox-converge-success` (filtered to this instance) — the staleness alert's `condition_absent` only arms once this series has a datapoint, and this metric filters on `textPayload` OR `jsonPayload.message` (the Ops Agent syslog pipeline may land the line in either), so a payload-shape regression is still caught HERE and nowhere else. A log line with no metric increment means the filter field is wrong — stop and fix `gcp/monitoring.tf` before onboarding anyone.
- **Dashboard populated:** the "Devbox Fleet" dashboard shows this instance's host metrics; per-process detail appears under the VM's Observability tab / `agent.googleapis.com/processes/*`.
- **IAP breakglass round-trip:** `gcloud compute ssh <name>-devbox --tunnel-through-iap --zone=<zone>` lands you on the box as your OS Login user.
- **Snapshot policy attached:** `gcloud compute disks describe devbox-data-<name> --zone=<zone>` lists the resource (snapshot-schedule) policy under `resourcePolicies`.
- **Generation bump is a clean rebuild:** bump the machine's `generation`, `terraform -chdir=gcp plan` → exactly **1** `random_uuid.devbox_generation` change + **1** `google_compute_instance.devbox` replacement + **1** `tailscale_tailnet_key.devbox` replacement for that key, and node identity persists (`/data/tailscale` survives — same Tailscale IP after apply).
- **After federation lands (step 5):** `ssh dev@<name>-devbox 'aws sts get-caller-identity --profile devbox-bedrock'` shows the `devbox-gcp-workload` assumed role; `bclaude` answers a prompt; the AssumeRoleWithWebIdentity event is visible in CloudTrail; plain `claude` / `aws` still use the dev's personal account.

### Step 5 — Bedrock federation (optional; any time after step 1)

Only for fleets that want the shared Bedrock path (`bclaude`). Mint the shared
workload role in `aws-federation/`, then wire it back into the GCP root. This
root uses **local state** (`aws-federation/terraform.tfstate`): it is gitignored,
so keep an encrypted backup after every apply. Select an AWS admin/deployer
credential through the standard AWS credential chain; the provider refuses an
account other than the configured `aws_account_id`.

```bash
set -euo pipefail
cp aws-federation/terraform.tfvars.example aws-federation/terraform.tfvars
# aws-federation/ trusts the GCP instance SA by its NUMERIC unique id.
SA_ID=$(terraform -chdir=gcp output -raw devbox_instance_sa_unique_id)
# In aws-federation/terraform.tfvars, replace aws_account_id and set
# sa_unique_id to $SA_ID. Keep audience equal to gcp's
# aws_federation_audience; project_tag is optional.
aws sts get-caller-identity  # verify the intended administrative AWS account
terraform -chdir=aws-federation init
terraform -chdir=aws-federation plan
terraform -chdir=aws-federation apply
ROLE_ARN=$(terraform -chdir=aws-federation output -raw role_arn)
# Back up aws-federation/terraform.tfstate to your encrypted admin store now.
# Paste $ROLE_ARN into gcp/terraform.tfvars as bedrock_role_arn, then:
terraform -chdir=gcp apply
SHA=$(terraform -chdir=gcp output -raw runtime_manifest_sha256)
scripts/gcp/sync-converge.sh <canary-machine> --manifest-sha "$SHA"
# On the canary, verify bclaude and the devbox-bedrock AWS profile now use the
# expected role; plain claude/aws must still use the dev's personal identity.
# Promote only after those candidate-pinned checks pass:
DEVBOX_RUNTIME_BUCKET=$(terraform -chdir=gcp output -raw runtime_bucket) \
  scripts/gcp/promote-runtime.sh "$SHA"
```

## Routine operations

- **Add a machine.** Append the entry to `var.devs` in `gcp/terraform.tfvars`, `terraform -chdir=gcp apply`. The Tailscale auth key mints under the gate's protection (the delegating `tag:devbox-key-minter`). Each machine's `machine_type`, `root_disk_gb`, `data_disk_gb`, and `swap_gib` override the fleet defaults — the bullets below cover changing them on a live box. Tell the dev: *"Your devbox is up — `ssh dev@<key>-devbox`."*
- **Grow a root disk.** `root_disk_gb` is a creation-only default (120 GB): routine applies do not resize existing roots, while a later instance rebuild uses the then-current configured size. To grow an existing root without replacement, first take or confirm a recent snapshot, run `gcloud compute disks resize <key>-devbox --size=<gb>GB --zone=<zone>`, and verify `lsblk` plus `df -h /`. The public Ubuntu image expands the root partition and filesystem automatically. Terraform intentionally ignores post-creation root-size drift, and Persistent Disks cannot shrink.
- **Roll out a runtime change (canary → promote).** `terraform -chdir=gcp apply` uploads the new content-addressed candidate. Canary one box, verify, then promote to the fleet:
  ```bash
  SHA=$(terraform -chdir=gcp output -raw runtime_manifest_sha256)
  scripts/gcp/sync-converge.sh <canary-machine> --manifest-sha "$SHA"   # force this box onto the candidate now
  # verify the canary, then:
  DEVBOX_RUNTIME_BUCKET=$(terraform -chdir=gcp output -raw runtime_bucket) \
    scripts/gcp/promote-runtime.sh "$SHA"                               # fleet converges within ~9h
  ```
- **Resize `machine_type`.** Change it in tfvars, `terraform -chdir=gcp apply`. `allow_stopping_for_update = true` stops and restarts the instance in place — NOT a rebuild (no generation bump, no key rotation, data disk untouched).
- **Grow the data disk.** Raise `data_disk_gb` in tfvars (grow-only — GCE rejects shrinks), `terraform -chdir=gcp apply`, then extend the filesystem on the box:
  ```bash
  ssh dev@<key>-devbox sudo resize2fs /dev/disk/by-id/google-data
  ```
- **Change swap.** Change `swap_gib` in tfvars, `terraform -chdir=gcp apply` (an in-place instance-metadata update). It applies at the next converge, when `devbox-converge` reads `devbox-swap-gib` metadata and exports `DEVBOX_SWAP_SIZE_GIB` for `devbox-memory-hotfix` — never a rebuild. Force it now with `scripts/gcp/sync-converge.sh <key>`.
- **Bump an installer pin.** `https://claude.ai/install.sh` and
  `https://chatgpt.com/codex/install.sh` are floating URLs pinned by sha256
  (`toolchain.claude_installer_sha256` / `codex_installer_sha256`), so a new
  upstream installer makes converge report the affected concern failing on a
  `sha256sum` mismatch. That failure is the design: only a box whose claude is
  already broken (or a new box bootstrapping Codex) waits on the bump —
  healthy boxes never re-download. From a trusted workstation, fetch the
  script, read the diff against what you expect, then update tfvars and roll
  out through the normal candidate → canary → promote flow:
  ```bash
  curl -fsSL https://claude.ai/install.sh | sha256sum
  curl -fsSL https://chatgpt.com/codex/install.sh | sha256sum
  ```
  The Paseo pin pair (`toolchain.paseo_cli_version` +
  `paseo_cli_tarball_sha256`) only moves when you choose a newer Paseo for
  new boxes:
  ```bash
  npm view @getpaseo/cli version
  curl -fsSL https://registry.npmjs.org/@getpaseo/cli/-/cli-<version>.tgz | sha256sum
  ```
- **Rebuild a box.** The only supported rebuild is a keeper change on `random_uuid.devbox_generation`: the machine's `generation` knob, `ubuntu_2404_image`, the boot template, or either Chrome wrapper. Never `terraform apply -replace=` an instance directly — that skips the lockstep Tailscale key rotation. `terraform -chdir=gcp plan` must show, for each affected machine, exactly 1 generation change + 1 instance replacement + 1 auth-key replacement; if the counts differ, stop, the keeper invariant is broken. `scripts/chrome-devtools-mcp-wrapper.sh` and `scripts/chrome-devtools-mcp-steered-wrapper.sh` are deliberately NOT day-2 (root-owned, they control Chrome's launch flags, `--user-data-dir` and headless mode), so wrapper edits go through this path. After the apply, walk the canary checklist above.

### Paseo installation ownership

New devboxes install [Paseo](https://github.com/getpaseo/paseo) below
`/home/dev/.local/share/paseo/npm`, owned by `dev`. The bootstrap install is
pinned: the toolchain fetches the exact `toolchain.paseo_cli_version` tarball
from the npm registry, verifies it against
`toolchain.paseo_cli_tarball_sha256`, and only then hands it to npm. Known
residual: the CLI's transitive npm dependencies still resolve from the
registry at install time under npm's own integrity metadata — the pin covers
the package itself, and closing the rest would take a package mirror the
fleet has deliberately not adopted. Paseo's
in-app updater is not a background auto-updater — it runs only when the dev
triggers an update from a connected Paseo client, and it then installs npm
latest, so boxes drift from the pin exactly when their dev chooses to. The
primary `/home/dev/.local/bin/paseo` launcher and its `/usr/local/bin/paseo`
fallback export that directory as `NPM_CONFIG_PREFIX`, so
Paseo's daemon self-updater can run its normal global npm update without sudo.
The user launcher precedes any NVM-global Paseo copy on the normal devbox
PATH. Do not set a persistent npm `prefix` in `/home/dev/.npmrc`; that conflicts
with the devbox's NVM-managed Node installation.

Verify the layout and the managed daemon:

```bash
ssh dev@<key>-devbox '
  command -v paseo
  paseo --version
  NPM_CONFIG_PREFIX=/home/dev/.local/share/paseo/npm npm -g ls @getpaseo/cli --depth=0
  test -w /home/dev/.local/share/paseo/npm/lib/node_modules/@getpaseo/cli
  paseo daemon status
  systemctl is-enabled paseo.service
  systemctl is-active paseo.service
'
```

`paseo daemon status` is read-only. Convergence reconciles and enables
`paseo.service` on every run, even when Paseo itself is already installed.
If a detached daemon is already running, the service leaves it alone
and waits; it takes over foreground supervision when that process exits. After
a reboot, systemd starts Paseo directly. To finish the handoff immediately,
run `paseo daemon stop`; the service begins managed startup on its next
five-second poll, though Paseo can take longer to report ready. Once systemd
owns the daemon, use `sudo systemctl restart paseo` for an explicit managed
restart.

### Claude Code installation

Claude Code is a dev-owned native install at `/home/dev/.local/bin/claude`,
installed once by `ensure_claude_code` and self-updating thereafter. The
*binary* is unpinned: `/var/lib/devbox-runtime/claude-code-installed` records
the version that was installed and is the only drift trail. To hold a box at
a version, run `claude install <version>` as `dev` on that box. The
*installer script* the repair path downloads IS pinned
(`toolchain.claude_installer_sha256` — see "Bump an installer pin" above):
install.sh's own manifest check shares an origin with the binary it fetches,
so only the org pin stands between a compromised `claude.ai/install.sh` and
root-timer-driven code execution on every box with a broken claude.

That marker is a cache of a live contract check (regular file, dev-owned,
executable, non-empty `--version`), recomputed every converge and **deleted
before any repair attempt**. So an absent marker means claude is currently
broken on that box, and three things deliberately stop: the old-install
cleanup, the agent-plugins concern, and every Bedrock-side action in
`devbox-bedrock-config` (the `bclaude`/`bdcc` wrappers, the `~/.bashrc`
retirement, and the Paseo provider). A box in that state keeps working on
whatever claude it already had.

Verify a box:

```bash
ssh dev@<name>-devbox '
  which -a claude
  claude --version
  cat /var/lib/devbox-runtime/claude-code-installed
  /usr/local/bin/bclaude --version
  jq .agents.providers.bclaude ~/.paseo/config.json
'
```

`which -a claude` may still list `~/.nvm/versions/node/*/bin/claude`:
cleanup removes the nvm package directory but leaves that symlink dangling
(a known, accepted defect). The package behind it is gone and the entry is
harmless — do not escalate on its presence alone.

`paseo provider ls` shows `bclaude` only after the daemon reloads the updated
config. Use `sudo systemctl restart paseo` when an immediate reload is wanted.

## Day-2 changes to `devbox-onboard` (no rebuild)

```bash
# Edit scripts/devbox-onboard, commit, then:
scripts/sync-onboard.sh            # every machine in the gcp/ root's state
scripts/sync-onboard.sh alice bob  # or just these machine keys
```

The script SSHes over Tailscale to each box and installs the latest
`devbox-onboard` at its root-owned destination, plus
`scripts/devbox-repos.default` **when that file is present** (it is gitignored,
so a clone without it simply skips that half). Devs whose
`~/.devbox-onboarded` sentinel exists are not re-prompted — tell the dev if the
new step matters to them, and note that a newly synced repo list does not
re-seed an existing `~/.devbox-repos`.

## Admin SSH and the dev's tmux

By default, interactive SSH drops you into a plain shell — tmux is opt-in per dev (`~/.auto-tmux`, see `/etc/profile.d/00-devbox-auto-tmux.sh`), so on most boxes there's nothing to bypass.

For a dev who HAS opted in, login auto-attaches to their `main` tmux session. For incident response — investigating a stuck process, reading logs, running ad-hoc commands without surfacing in their session — bypass the auto-attach by skipping `/etc/profile`:

```bash
ssh dev@<dev>-devbox -t 'bash --noprofile'
```

`--noprofile` skips `/etc/profile` (and thus `/etc/profile.d/*`), so the auto-tmux hook never fires. You get a standalone bash session that does not appear in `tmux ls`. The dev's tmux session is unaffected. `-t` forces TTY allocation (without it `bash` exits immediately on stdin EOF).

For longer admin work where YOU want tmux's drop-survival but separate from the dev's `main`, attach to a different session name explicitly:

```bash
ssh dev@<dev>-devbox -t 'tmux new-session -A -s admin'
```

This creates/attaches `admin` while leaving the dev's `main` untouched. The dev will see your `admin` session if they run `tmux ls` — there is no isolation between sessions on the same Unix user, only namespacing.

## Steerable Chrome health

The long-lived Chrome that backs the `chrome-devtools-steered` MCP server is `chrome-steered.service` on each devbox. Chrome itself binds CDP (the Chrome DevTools Protocol) to `127.0.0.1:9222`; the boot script publishes that port to the tailnet via `tailscale serve --bg --tcp=9222 tcp://127.0.0.1:9222`, so a dev's laptop reaches it as `<dev>-devbox:9222` with no SSH tunnel.

Quick health probes:

```bash
ssh dev@<dev>-devbox -t 'sudo systemctl status chrome-steered'
ssh dev@<dev>-devbox -t 'sudo journalctl -u chrome-steered --since "1 hour ago"'
ssh dev@<dev>-devbox -t 'curl -fsS http://127.0.0.1:9222/json/version'
ssh dev@<dev>-devbox -t 'tailscale serve status'
```

The CDP `/json/version` probe is what the `chrome-devtools-mcp-steered-wrapper` itself uses as a readiness check; a healthy box returns a JSON body containing `webSocketDebuggerUrl`. `tailscale serve status` should show `tcp://:9222 → tcp://127.0.0.1:9222`.

### Security baseline (accept or tighten before adding devs)

By baseline:

- The dev's Tailscale identity reaches `<their>-devbox:9222` — their own steered Chrome. `9222` is published to the tailnet by `tailscale serve` at boot, so no SSH tunnel is involved.
- **Admins reach every devbox on every port, `:9222` included.** `admin_acl_rule` in `gcp/tailscale-acl.tf` grants `group:devbox-admins` the destination `tag:devbox-<key>:*` for every machine. Anyone holding an admin tailnet identity can therefore drive any dev's steered Chrome, with full access to whatever that dev is logged into in it (mail, chat, cloud consoles, internal dashboards).
- **Every tailnet member reaches ports 3000 and 3005 on every devbox** (`shared_dev_ports_rule`) — the shared dev-preview ports. Nothing else is shared between members.
- **Every devbox tag carries the `funnel` node attribute** (`funnel_node_attrs` in `gcp/tailscale-acl.tf`), so any dev can expose a port on their own box to the **public internet** with Tailscale Funnel — a documented dev feature, not an accident. The same attribute is granted to `autogroup:member`, so it also covers each member's own untagged devices (the devbox tags are listed explicitly because `autogroup:member` excludes tagged nodes). If you do not want that reach, remove `funnel_node_attrs` from the rendered document and re-apply — note that this also breaks `tests/gcp-tailscale-test.sh`, which asserts the rendered ACL contains `funnel`; drop that assertion in the same change.
- Chrome runs with `--remote-allow-origins=*` (in the `chrome-steered.service` unit written by the boot template). This relaxes Chrome's CDP **WebSocket Origin check** on `/devtools/page/<id>` upgrades — without it, the DevTools UI on a laptop cannot drive remote pages. It does NOT relax Chrome's **DNS-rebinding Host guard** on the HTTP discovery endpoints (`/json/*`); that guard hard-codes the allowed `Host:` to `localhost` or an IP literal and has no Chrome flag to extend it. Devs must therefore point `chrome://inspect` at the box's Tailscale IPv4 (e.g. `100.x.y.z:9222`), not the MagicDNS hostname.

To **tighten** so admins cannot reach `:9222`: in `gcp/tailscale-acl.tf`, replace `admin_acl_rule`'s `tag:devbox-<key>:*` destination with the explicit port set admins should keep — e.g. `tag:devbox-<key>:22` for SSH only — and re-apply. Each dev's own per-machine rule is unaffected, so this costs admins port reach, not SSH. Breakglass over IAP is unaffected either way.

To **disable Serve entirely** on one box (revert it to an SSH-tunnel-only flow):

```bash
ssh dev@<dev>-devbox -t 'tailscale serve --yes --tcp=9222 off'
```

The Serve config lives in tailscaled state on the persistent data disk (`/data/tailscale`), so `off` removes the mapping for that box only. It survives reboots and converges (no converge step touches `tailscale serve`), but **NOT a rebuild**: the boot script's one-time provisioning is gated by a marker on the root disk, a rebuild gives the instance a fresh root disk, and the re-run publishes `:9222` again. Re-apply `off` after every rebuild of that box. Re-enable normally with `tailscale serve --yes --bg --tcp=9222 tcp://127.0.0.1:9222`. `--yes` is required because `tailscale serve` prompts before modifying existing state, which would block any non-interactive invocation.

Serve-off is therefore a courtesy setting, not a control: the box runs `tailscaled --operator=dev`, so the dev can re-publish `:9222` at any time (deliberately, or as collateral of a `tailscale funnel reset` / serve reconfiguration) without admin involvement. If admin or member reach to `:9222` must actually be prevented, the ACL edit above is the durable lever.

## Offboarding (integrity-first)

`google_compute_disk.data` has `prevent_destroy = true` and the lifecycle block is shared across all `for_each` keys, so you cannot flip the flag for one machine. The supported path is stop → snapshot → **verified test-restore** → `state rm` → tfvars drop → apply → manual delete.

```bash
gcloud compute instances stop <key>-devbox --zone=<zone>          # integrity boundary
gcloud compute disks snapshot devbox-data-<key> --zone=<zone> \
  --snapshot-names=offboard-<key>-$(date +%Y%m%d)
# MANDATORY test-restore before any deletion:
gcloud compute disks create restore-verify --zone=<zone> --source-snapshot=offboard-<key>-<date>
# attach read-only to a scratch VM, mount, verify /data/home/dev/work,
# /data/docker, /data/tailscale, ~/.devbox-onboarded exist; then delete
# the scratch VM + restore-verify disk. If verification fails: STOP.
terraform -chdir=gcp state rm 'google_compute_attached_disk.data["<key>"]' \
  'google_compute_disk.data["<key>"]' 'google_compute_disk_resource_policy_attachment.data["<key>"]'
# Drop the machine from gcp/terraform.tfvars devs, then apply: this destroys
# the instance and its consumed Tailscale auth key. The data disk survives —
# the state rm above means Terraform no longer manages it, so it is not in the
# destroy plan.
terraform -chdir=gcp apply
# The instance is gone, so the disk has no attached users and can now be
# deleted. (Attempting this while the stopped instance still existed would be
# rejected — GCE lists the instance under the disk's users, and state rm only
# stops Terraform tracking; it does not detach anything in GCE.)
gcloud compute disks delete devbox-data-<key> --zone=<zone>
# Finally, delete the Tailscale device from the admin panel.
```

**If test-restore fails for ANY reason, STOP** — do not `state rm` or delete. Investigate the snapshot, take a fresh one, verify again before destroying the source disk. To offboard a user who owns several machines, repeat for every machine key (`terraform -chdir=gcp output -json devbox_data_disk_names | jq 'keys'` lists them) before deleting the whole user entry.

## Breakglass (reserved for when Tailscale is down)

The three IAM grants that make this work (`roles/compute.osAdminLogin`,
`roles/iap.tunnelResourceAccessor` on the project, `roles/iam.serviceAccountUser`
on the `devbox-instance@` SA) are held only by the admin group in
`devbox_admins_group` (e.g. `devbox-admins@example.com`) — that is the complete
breakglass set.

```bash
# IAP + OS Login SSH (port 22 is open only to Google's IAP range 35.235.240.0/20):
gcloud compute ssh <key>-devbox --tunnel-through-iap --zone=<zone>

# Read-only diagnostics when SSH itself won't come up:
gcloud compute instances get-serial-port-output <key>-devbox --zone=<zone>

# Interactive serial console — LAST resort. Enable, connect, then REMOVE the metadata:
gcloud compute instances add-metadata <key>-devbox --zone=<zone> \
  --metadata=serial-port-enable=TRUE
# ... connect via the console, do the minimum, then:
gcloud compute instances remove-metadata <key>-devbox --zone=<zone> \
  --keys=serial-port-enable
```

IAP / OS Login sessions land in Cloud Audit Logs (Admin Activity). Always disable the serial port again when done.

## Quarterly restore drill

Prove the scheduled snapshots are restorable. Restore the latest scheduled snapshot of one machine to a scratch disk, attach it read-only to a scratch VM, verify the marker paths, tear everything down, and log the drill below.

```bash
# Latest scheduled snapshot for one machine's data disk:
SNAP=$(gcloud compute snapshots list \
  --filter="sourceDisk~devbox-data-<key>" --sort-by=~creationTimestamp \
  --limit=1 --format='value(name)')
gcloud compute disks create drill-verify --zone=<zone> --source-snapshot="$SNAP"
# attach read-only to a scratch VM, mount, confirm /data/home/dev/work,
# /data/docker, /data/tailscale, and ~/.devbox-onboarded are present + readable.
# Then tear down: detach, delete drill-verify disk + scratch VM.
```

| Date | Machine key | Snapshot restored | Markers verified | Operator | Result |
|------|-------------|-------------------|------------------|----------|--------|
|      |             |                   |                  |          |        |
