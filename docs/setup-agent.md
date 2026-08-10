# Agent-assisted setup

Set up a devbox fleet by pasting one prompt into an AI coding agent
(Claude Code, Codex CLI, Cursor) running in your clone of this repo.

## The prompt (copy everything in the box)

> Read AGENTS.md, then follow the playbook in docs/setup-agent.md to set up
> devbox-fleet for my organization. Interview me for the values you need,
> show me every cloud change and get my OK before applying it, and never ask
> me to paste secrets into chat.

## Ground rules (agent MUST follow)

1. **Mutation approval gate.** For EVERY cloud mutation — each `terraform`
   apply, each `gcloud` command that creates or changes resources, each
   runtime promotion: show the user what will change (for Terraform: create
   a saved plan and present its summary), get explicit confirmation, then
   execute exactly what was approved (for Terraform: apply that saved plan
   file). Nothing is created, changed, or promoted on your own initiative.
2. **Secrets stay out of chat.** The user pastes the Tailscale OAuth
   id/secret into `gcp/terraform.tfvars` themselves. After that, edit tfvars
   only by targeted replacement — never regenerate the file (the secret must
   survive your edits).
3. `docs/admin-runbook.md` is authoritative. When this playbook and the
   runbook differ, the runbook wins.

## Playbook

Nine steps. Each one ends with what to verify before moving to the next —
if a verification fails, stop and fix it there rather than pressing on.

### Step 1 — Read `AGENTS.md`; confirm you're in a clone

```bash
test -f AGENTS.md
test -f docs/setup-agent.md
git rev-parse --is-inside-work-tree
```

Read the whole of `AGENTS.md` before continuing, including its "Guardrails —
do NOT fix these" section — those guardrails override any shortcut this
playbook might otherwise tempt you toward.

Then run an early tool check so missing prerequisites surface NOW, not
mid-bootstrap:

```bash
scripts/preflight
```

At this stage the config checks legitimately fail — nothing is configured
yet. Read the output per check: every `cli-*` check must already PASS
(terraform, gcloud, jq, git); `gcloud-adc` FAILs until step 3's ADC login
and the `config-*`/`bucket-reachable`/`apis-enabled` checks fail or skip
until steps 3–5 — all expected here. If any `cli-*` check fails, stop and
have the user install that tool before the interview.

**Verify:** the three repo commands succeed (`git rev-parse
--is-inside-work-tree` prints `true`), every `cli-*` preflight check is
PASS, and you can summarize `AGENTS.md`'s guardrails back before moving on.

### Step 2 — Interview the user

Collect every value below before touching a file:

- GCP organization id and billing account.
- GCP project id — an existing project, or a new one you'll create in step 3.
- `gcp_region`, and the zone(s) their machines will live in (each machine's
  `zone` must belong to that region).
- **Tailnet: a tailnet dedicated to devboxes (recommended), or an existing
  tailnet?**
  - Dedicated: continue normally.
  - Existing: stop and explain the takeover before doing anything else —
    once `manage_tailscale_acl = true`, this repo becomes the sole writer of
    that tailnet's ACL and replaces the whole policy document on every
    apply. Tell the user they must merge their current policy into
    `gcp/tailscale-acl.tf` (see `docs/admin-runbook.md`, "One-time Tailscale
    setup" and "First apply") before any gate work in step 8, and do not let
    them proceed past the ACL preview in step 8 until the rendered, merged
    document is what they intend to own.
- Admin emails: `devbox_admins_group`, `devbox_alert_email`,
  `tailscale_admin_emails`.
- The dev list: for each dev, a machine key, their GitHub username, and
  their Tailscale email. **Record this now but do not write it into `devs`
  yet** — `gcp/variables.tf` rejects a non-empty `devs` while
  `manage_tailscale_acl = false`, and the gate stays closed until step 8.
- The org's repo list (owner/repo pairs) for `scripts/devbox-repos.default`.
- Bedrock access: now (right after the step 8 canary), later, or never.

**Verify:** read the full list back to the user verbatim and get explicit
confirmation before step 3. Confirm out loud that `devs` stays `{}` no
matter how many devs they just listed — it is not written until step 8.

### Step 3 — GCP bootstrap

Mirrors the runbook's "One-time GCP bootstrap." Some of these commands need
org- or billing-account permissions you cannot verify you have, two require
interactive browser auth (the CLI login and the ADC login — gcloud keeps
these as SEPARATE credentials: the CLI login is what every `gcloud` command
here runs under, and it must happen before any of them; ADC is what
Terraform uses later), and one — the admin-group owner binding — must
never be self-managed by Terraform or an agent (see the comment in
`gcp/iam.tf`). Hand the human-only commands to the human as copy-paste
commands and wait for them to confirm each is done; propose the remaining
three yourself under the mutation approval gate (ground rule 1) and run them
only once approved.

First — regardless of new or existing project, and before ANY other gcloud
command in this playbook (including the read-only existing-project checks
just below) — the human authenticates the gcloud CLI itself:

```bash
gcloud auth list    # skip the next line if the intended admin account is already active
gcloud auth login
```

**If the user chose an existing project in step 2:** drop the
`gcloud projects create` line below, and drop the billing-link line too if
billing is already linked (`gcloud billing projects describe <project-id>`
shows it). First confirm the project exists with
`gcloud projects describe <project-id>` (read-only). The owner binding and
ADC login below, and the three gate-proposed commands after them, are still
required.

Hand to the human — they run these themselves, then tell you when each has
finished:

```bash
gcloud projects create your-project-id --organization=<ORG_ID>
gcloud billing projects link your-project-id --billing-account=<BILLING_ACCOUNT>
gcloud projects add-iam-policy-binding your-project-id \
  --member="group:devbox-admins@example.com" --role="roles/owner"
gcloud auth application-default login
```

Propose under the gate, then run once the user approves:

```bash
gcloud services enable compute.googleapis.com iam.googleapis.com iap.googleapis.com \
  storage.googleapis.com monitoring.googleapis.com logging.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=your-project-id
gcloud storage buckets create gs://your-tfstate-bucket --project=your-project-id \
  --location=us-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://your-tfstate-bucket --versioning
```

**Verify:**

```bash
gcloud projects describe your-project-id --format='value(projectId)'
gcloud services list --enabled --project=your-project-id --format='value(config.name)' \
  | rg -x '(compute|iam|iap|storage|monitoring|logging|cloudresourcemanager)\.googleapis\.com'
gcloud storage buckets describe gs://your-tfstate-bucket --format='value(name)'
```

All three must print output (no errors) before continuing.

### Step 4 — Generate the three config files (gate stays closed)

```bash
cp gcp/backend.hcl.example gcp/backend.hcl
cp gcp/terraform.tfvars.example gcp/terraform.tfvars
cp scripts/devbox-repos.example scripts/devbox-repos.default
```

Edit the three files from the step 2 interview answers:

- `backend.hcl`: `bucket` = the tfstate bucket created in step 3.
- `terraform.tfvars`: `gcp_project_id`, `gcp_region`, `tailscale_admin_emails`,
  `devbox_admins_group`, `devbox_alert_email`. Leave `manage_tailscale_acl =
  false` and `devs = {}` exactly as they are, and leave
  `tailscale_oauth_client_id`, `tailscale_oauth_client_secret`, and
  `tailscale_tailnet` as their placeholder values — step 5 fills those, and
  only the user fills them.
- `scripts/devbox-repos.default`: the org's repo list from the interview.

**Verify:**

```bash
test -f gcp/backend.hcl
test -f gcp/terraform.tfvars
test -f scripts/devbox-repos.default
rg -n 'manage_tailscale_acl\s*=\s*false' gcp/terraform.tfvars
rg -n 'devs\s*=\s*\{\}' gcp/terraform.tfvars
```

All five must pass before continuing.

### Step 5 — Tailscale setup (human-only steps, then the user fills the secret)

These steps happen in the Tailscale admin web console — there is no CLI
command for them. Present the exact instructions below to the user and
wait for them to confirm each is done.

1. **Create the tailnet** — skip this item if the user chose an existing
   tailnet in step 2 (the merge-policy requirement from step 2 still gates
   step 8). Otherwise: create a tailnet at https://login.tailscale.com/,
   invite the admin email from step 2, and accept the invite.
2. **Seed the delegating tag before creating the OAuth client.** In the
   Tailscale admin panel's Access controls editor, merge this entry into
   the existing `tagOwners` object and save the policy — preserve every
   other rule already there, this is a minimal seed, not the takeover:

   ```json
   "tagOwners": {
     "tag:devbox-key-minter": ["autogroup:admin"]
   }
   ```

3. **Create one OAuth client.** Admin panel → Trust credentials →
   Credential → OAuth → create ONE client with BOTH scopes: `auth_keys`
   (write, tag-restricted to `tag:devbox-key-minter`) and `policy_file`
   (write).

Then tell the user: paste the client id and secret into
`gcp/terraform.tfvars` yourself, as `tailscale_oauth_client_id` and
`tailscale_oauth_client_secret`, and the tailnet name as `tailscale_tailnet`
— never paste them into this chat. Treat this credential like an admin
credential.

After this point, edit `gcp/terraform.tfvars` only by targeted replacement
(changing one line in place) — never regenerate the file, or the secret is
lost.

**Verify (without ever printing the secret itself):**

```bash
rg -q 'tailscale_oauth_client_id\s*=\s*"REPLACE"' gcp/terraform.tfvars \
  && echo "still a placeholder" || echo "client id set"
rg -q 'tailscale_oauth_client_secret\s*=\s*"REPLACE"' gcp/terraform.tfvars \
  && echo "still a placeholder" || echo "client secret set"
rg -q 'tailscale_tailnet\s*=\s*"example\.com"' gcp/terraform.tfvars \
  && echo "still a placeholder" || echo "tailnet set"
```

All three must report the non-placeholder branch before continuing.

### Step 6 — Run `scripts/preflight --json` until it passes

```bash
scripts/preflight --json
```

**Verify:**

```bash
scripts/preflight --json | jq -e '.ok == true'
```

If `ok` is `false`, fix whatever each failing check's `fix` field says —
never invent your own remediation — and re-run until `jq -e '.ok == true'`
succeeds.

### Step 7 — Plumbing apply and the first promotion

```bash
terraform -chdir=gcp init -backend-config=backend.hcl
terraform -chdir=gcp validate
```

Under the mutation approval gate (ground rule 1), create a saved plan before
touching anything:

```bash
terraform -chdir=gcp plan -out=plumbing.tfplan
terraform -chdir=gcp show plumbing.tfplan
```

Show the user this plan's summary. It must contain **no `tailscale_acl`
resource and no `google_compute_instance`** — plumbing only (bucket, IAM,
network, monitoring, runtime candidate upload). Get explicit confirmation,
then apply exactly that saved plan:

```bash
terraform -chdir=gcp apply plumbing.tfplan
```

Whatever the outcome — success, failure, or the user rejecting the plan so
you never ran the apply — delete the saved plan now. It contains evaluated
sensitive variables, and keeping the `rm` out of the apply block means a
failed apply stays visible instead of being masked by a succeeding cleanup:

```bash
rm -f gcp/plumbing.tfplan
```

No boxes exist yet, so the initial runtime promotion is risk-free — show the
user the command below, get confirmation, then run it:

```bash
DEVBOX_RUNTIME_BUCKET=$(terraform -chdir=gcp output -raw runtime_bucket) \
  scripts/gcp/promote-runtime.sh $(terraform -chdir=gcp output -raw runtime_manifest_sha256)
```

Then show the user the gate-closed ACL skeleton (read-only, not a mutation):

```bash
terraform -chdir=gcp output -raw devbox_acl_json | jq .
```

**Verify:** `terraform -chdir=gcp validate` prints `Success!`; the plan you
showed the user before applying contained no `tailscale_acl` resource and no
`google_compute_instance`; `promote-runtime.sh` printed `promoted <sha> →
gs://.../runtime/manifest.json`; the ACL skeleton is valid JSON (piping it
through `jq -e .` exits `0`) and shows only the admin group, the
`tag:devbox-key-minter` tag owner, the admin-self rule, and node attributes
— no per-machine rules yet.

### Step 8 — First machine: open the gate

In `gcp/terraform.tfvars`, by targeted edit, set `manage_tailscale_acl =
true` and add the user's own first machine to `devs`. This only stages the
change — the gate is not open until the apply below actually completes.

Run the runbook's plan-and-preview commands first, in their own fence —
every line is byte-identical to the runbook, with one line appended so the
plan survives into the next, separate step:

```bash
set -euo pipefail
first_plan_dir="$(mktemp -d)"
first_plan="$first_plan_dir/first-machine.tfplan"
terraform -chdir=gcp plan -out="$first_plan"
terraform -chdir=gcp show -json "$first_plan" \
  | jq -er '.planned_values.outputs.devbox_acl_json.value | select(type == "string" and length > 0)' \
  | jq -e .
# STOP if this is not the complete policy you intend to own.
printf '%s\n' "$first_plan_dir" > /tmp/devbox-setup-agent-first-plan-dir
```

**Stop here.** Show the extracted ACL to the user and get their explicit
confirmation before going any further — check every group, owner, packet
rule, SSH rule, node attribute, and test. On an existing tailnet (step 2), do
not go past this point until the rendered document is exactly the merged
policy the user intends to own. Do not run the next block on your own
initiative — run it only once the user has explicitly approved what you just
showed them.

Only after that approval, apply that exact plan and clean up. This is a
separate command from the block above, so the shell variables it set do not
carry over; `first_plan_dir` and `first_plan` are redefined here from the
file that block wrote, then `first_plan` is derived exactly as before:

```bash
set -euo pipefail
first_plan_dir="$(cat /tmp/devbox-setup-agent-first-plan-dir)"
first_plan="$first_plan_dir/first-machine.tfplan"
terraform -chdir=gcp apply "$first_plan"
rm -f -- "$first_plan" && rmdir -- "$first_plan_dir"
rm -f /tmp/devbox-setup-agent-first-plan-dir
```

You never run the `apply` line on your own initiative — the user approves
this mutation like every other one. If the user does not approve — you stop
before running the block above — or the block fails partway (its `set -e`
stops before the cleanup lines), still delete the plan yourself with this
self-contained abort block, then go back to adjusting tfvars or re-planning:

```bash
set -euo pipefail
first_plan_dir="$(cat /tmp/devbox-setup-agent-first-plan-dir)"
first_plan="$first_plan_dir/first-machine.tfplan"
rm -f -- "$first_plan" && rmdir -- "$first_plan_dir"
rm -f /tmp/devbox-setup-agent-first-plan-dir
```

The plan file contains evaluated sensitive variables and must not be left
behind; the last line above also removes the bridge pointer file so a later
run of this step starts clean.

Once applied, walk the canary checklist on the new box (`<name>` is the
machine key you just added to `devs`):

```bash
ssh dev@<name>-devbox true
ssh dev@<name>-devbox 'mount | grep /data'
ssh dev@<name>-devbox 'systemctl list-timers devbox-converge.timer'
gcloud compute ssh <name>-devbox --tunnel-through-iap --zone=<zone>
```

In Cloud Logging, confirm the boot-time converge emits a line matching
`resource.type="gce_instance" AND (textPayload:"devbox-converge-success" OR
jsonPayload.message:"devbox-converge-success")`, then confirm in Metrics
Explorer that the log-based metric `logging.googleapis.com/user/devbox-converge-success`
actually incremented for this instance — do not skip that second half of the
check.

**Verify:** the first `ssh` command connects; the second's output contains
`/data`; the third shows a next run within ~9h; the fourth
(`gcloud compute ssh ... --tunnel-through-iap`) lands you on the box; the
Cloud Logging line above is present AND the paired metric actually
incremented. From this apply onward, treat the tailnet ACL as owned by this
root — never flip the gate back, and never suggest `terraform apply
-replace=` on this or any instance.

### Step 9 — Bedrock federation (optional; only after step 8's canary passes)

Only if the user chose "now" or "later" in step 2, and only once every item
in step 8's canary checklist is green. Follow the runbook's exact commands
("First apply", Step 5); ground rule 1 still applies to every mutation here,
so where the runbook shows a bare `plan`/`apply` for a human typing it
directly, use the same saved-plan pattern as step 7 instead.

```bash
cp aws-federation/terraform.tfvars.example aws-federation/terraform.tfvars
terraform -chdir=gcp output -raw devbox_instance_sa_unique_id
```

In `aws-federation/terraform.tfvars`, by targeted edit, replace
`aws_account_id` and set `sa_unique_id` to the numeric id just printed above.
Keep `audience` equal to the GCP root's `aws_federation_audience`;
`project_tag` is optional.

```bash
aws sts get-caller-identity
```

Show this identity to the user and get their confirmation that it is the
intended administrative AWS account before continuing.

```bash
terraform -chdir=aws-federation init
terraform -chdir=aws-federation plan -out=federation.tfplan
terraform -chdir=aws-federation show federation.tfplan
```

Show this plan's summary to the user. Get explicit confirmation, then apply
exactly that saved plan:

```bash
terraform -chdir=aws-federation apply federation.tfplan
```

Whatever the outcome — success, failure, or rejection before the apply —
delete the saved plan now (evaluated sensitive variables; a separate `rm`
also keeps a failed apply visible):

```bash
rm -f aws-federation/federation.tfplan
```

On success, read the role ARN:

```bash
terraform -chdir=aws-federation output -raw role_arn
```

Tell the user to back up `aws-federation/terraform.tfstate` to their
encrypted admin store now — this root uses local state and it is gitignored.
Then, by targeted edit, paste the role ARN just printed above into
`gcp/terraform.tfvars` as `bedrock_role_arn`.

Re-apply the GCP root under the gate, the same saved-plan way as step 7:

```bash
terraform -chdir=gcp plan -out=bedrock.tfplan
terraform -chdir=gcp show bedrock.tfplan
```

Show the user this plan's summary, get explicit confirmation, then apply it:

```bash
terraform -chdir=gcp apply bedrock.tfplan
```

As with every saved plan: delete it now regardless of the apply's outcome —
including if the user rejected it:

```bash
rm -f gcp/bedrock.tfplan
```

Show the user the canary command below, get confirmation, then run it:

```bash
SHA=$(terraform -chdir=gcp output -raw runtime_manifest_sha256)
scripts/gcp/sync-converge.sh <canary-machine> --manifest-sha "$SHA"
```

On the canary, confirm `ssh dev@<canary-machine>-devbox 'aws sts
get-caller-identity --profile devbox-bedrock'` shows the
`devbox-gcp-workload` assumed role, that `bclaude` answers a prompt, and
that the AssumeRoleWithWebIdentity event is visible in CloudTrail — plain
`claude`/`aws` on that box must still use the dev's personal identity.
Promote only after those candidate-pinned checks pass — show the user the
promotion command below, get confirmation, then run it:

```bash
SHA=$(terraform -chdir=gcp output -raw runtime_manifest_sha256)
DEVBOX_RUNTIME_BUCKET=$(terraform -chdir=gcp output -raw runtime_bucket) \
  scripts/gcp/promote-runtime.sh "$SHA"
```

**Verify:** the AWS identity shown matched what the user confirmed; the
aws-federation apply produced a non-empty `role_arn` output; the GCP
re-apply's plan (shown to the user before applying) changed only what the
federation wiring requires; the canary's `aws sts get-caller-identity
--profile devbox-bedrock` and `bclaude` checks above both pass while plain
`claude`/`aws` are unaffected; the promotion command printed `promoted $SHA
→ gs://.../runtime/manifest.json`.

## Never do

- Never apply, create, or promote anything without the mutation approval
  gate above.
- Never flip `manage_tailscale_acl` without the saved-plan ACL preview
  reviewed by the user.
- On an existing tailnet, never proceed past the ACL preview until the
  merged policy renders what the user intends to own.
- Never set a non-empty `devs` while the gate is closed.
- Never commit `gcp/terraform.tfvars`, `gcp/backend.hcl`, or
  `scripts/devbox-repos.default`.
- Never `terraform apply -replace=` an instance.
- Never write the runtime pointer except via
  `scripts/gcp/promote-runtime.sh`.
- Never ask for or store secrets in chat when a file edit by the user
  suffices.
