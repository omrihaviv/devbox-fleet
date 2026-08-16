variable "gcp_project_id" {
  description = "Dedicated devbox GCP project. The project boundary IS the admin-control boundary: only devbox-admins hold any role here."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.gcp_project_id))
    error_message = "gcp_project_id must be a valid GCP project ID."
  }
}

variable "gcp_region" {
  description = "Region for all devbox resources (single-region by design)."
  type        = string
  default     = "us-central1"
}

variable "machine_type" {
  description = "Default GCE machine type for machines that don't override per-machine. Any x86_64 type incl. custom (e.g. n2-custom-8-32768). ARM families are rejected because the pinned image is amd64 — GCE would fail the apply loudly anyway (arch mismatch); the validation just fails earlier with a clearer message."
  type        = string
  default     = "n2-standard-4"
  validation {
    condition     = !can(regex("^(t2a|c4a|n4a)-", var.machine_type))
    error_message = "machine_type must be x86_64: ARM families (t2a-, c4a-, n4a-) are rejected — the pinned Ubuntu image is amd64."
  }
}

variable "root_disk_gb" {
  description = "Default root-disk size in GB for newly created or rebuilt machines. Creation-only: Terraform intentionally ignores size drift after creation so existing disks can be grown online without instance replacement."
  type        = number
  default     = 120
  validation {
    condition     = var.root_disk_gb >= 10 && var.root_disk_gb <= 65536 && floor(var.root_disk_gb) == var.root_disk_gb
    error_message = "root_disk_gb must be a whole number between 10 and 65536."
  }
}

variable "data_disk_gb" {
  description = "Default size in GB of the persistent data disk per machine. Grow-only: GCE rejects shrinks."
  type        = number
  default     = 120
}

variable "swap_gib" {
  description = "Default root-volume swapfile size in GiB. Delivered per-machine via instance metadata (devbox-swap-gib), applied by devbox-memory-hotfix at converge time — never a rebuild."
  type        = number
  default     = 64
  validation {
    condition     = var.swap_gib >= 0 && var.swap_gib <= 64
    error_message = "swap_gib must be between 0 and 64."
  }
}

variable "ubuntu_2404_image" {
  description = "Pinned Ubuntu 24.04 LTS amd64 image NAME in project ubuntu-os-cloud (e.g. ubuntu-2404-noble-amd64-v20260805). MUST be a pinned name, never an image-family lookup — the image is a generation keeper so a bump rotates instance + Tailscale auth key in lockstep."
  type        = string
  validation {
    condition     = can(regex("^ubuntu-2404-noble-amd64-v[0-9]+$", var.ubuntu_2404_image))
    error_message = "ubuntu_2404_image must be a pinned image name like ubuntu-2404-noble-amd64-v20260805."
  }
}

variable "toolchain" {
  description = "Runtime-converged tool versions are pinned or deliberately floating when set to latest. Delivered via the GCS manifest; changing the configured values must not force instance replacement."
  type = object({
    tailscale_version           = string
    docker_ce_version           = string
    gh_version                  = string
    system_node_version         = string
    nvm_version                 = string
    nvm_install_sha256          = string
    node_version                = string
    google_chrome_version       = string
    chrome_devtools_mcp_version = string
    vscode_version              = optional(string, "latest")
    aws_cli_version             = string # dev tool + devbox-aws-creds dependency; NOT in boot/converge fetch path
    aws_cli_install_sha256      = string
    # sha256 pins for the two FLOATING installer scripts (claude.ai/install.sh
    # and chatgpt.com/codex/install.sh — upstream edits them in place). When
    # upstream ships a new installer these go stale and the affected
    # repair/bootstrap path fails loudly until an admin verifies the new
    # script and bumps the pin (docs/admin-runbook.md). The CLIs themselves
    # deliberately stay unpinned and self-update after install.
    claude_installer_sha256 = string
    codex_installer_sha256  = string
    # Exact @getpaseo/cli version + sha256 of its registry tarball
    # (immutable per version). Governs only the unattended first-bootstrap
    # install; dev-triggered in-app Paseo updates still float.
    paseo_cli_version        = string
    paseo_cli_tarball_sha256 = string
    # Pinned commits (upstream HEADs as of 2026-07-24); shallow-fetched by
    # sha, so the pin self-verifies.
    tmux_resurrect_commit = optional(string, "cff343cf9e81983d3da0c8562b01616f12e8d548")
    tmux_continuum_commit = optional(string, "0698e8f4b17d6454c71bf5212895ec055c578da0")
  })

  validation {
    condition = (
      can(regex("^[0-9a-fA-F]{64}$", var.toolchain.nvm_install_sha256)) &&
      can(regex("^[0-9a-fA-F]{64}$", var.toolchain.aws_cli_install_sha256)) &&
      can(regex("^[0-9a-fA-F]{64}$", var.toolchain.claude_installer_sha256)) &&
      can(regex("^[0-9a-fA-F]{64}$", var.toolchain.codex_installer_sha256)) &&
      can(regex("^[0-9a-fA-F]{64}$", var.toolchain.paseo_cli_tarball_sha256))
    )
    error_message = "toolchain sha256 pins (nvm_install_sha256, aws_cli_install_sha256, claude_installer_sha256, codex_installer_sha256, paseo_cli_tarball_sha256) must each be a full 64-hex SHA-256 value; replace the example placeholders before planning."
  }
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.toolchain.paseo_cli_version))
    error_message = "toolchain.paseo_cli_version must be an exact release version (e.g. 0.4.0), never latest — it addresses the pinned registry tarball."
  }
}

variable "ops_agent_version" {
  description = "Pinned google-cloud-ops-agent apt package version (e.g. 2.55.0). Delivered via manifest; converged by scripts/gcp/devbox-observability."
  type        = string
}

variable "devs" {
  description = "Per-user configuration; machine sub-key `primary` flattens to the bare user key, others to <user>-<machine>. MUST be {} until manage_tailscale_acl = true: machines without Terraform-owned tag-owner declarations could never join the tailnet."
  type = map(object({
    github_user     = string
    tailscale_email = string
    machines = map(object({
      zone         = string
      generation   = optional(number, 1)
      machine_type = optional(string)
      root_disk_gb = optional(number)
      data_disk_gb = optional(number)
      swap_gib     = optional(number)
      extra_repos  = optional(list(string), [])
    }))
  }))
  default = {}

  # ACL ownership gate: no machines may exist before this root owns the ACL.
  validation {
    condition     = var.manage_tailscale_acl || length(var.devs) == 0
    error_message = "devs must be empty until manage_tailscale_acl = true (the root must own the tailnet ACL before any machine's tag-owner declaration can exist)."
  }
  validation {
    condition = alltrue([
      for d in var.devs :
      can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", d.tailscale_email))
    ])
    error_message = "Every devs[*].tailscale_email must look like a valid email address — per-machine ACL isolation is keyed off this string."
  }
  validation {
    condition     = length(distinct([for d in var.devs : lower(trimspace(d.tailscale_email))])) == length(var.devs)
    error_message = "devs[*].tailscale_email must be unique (case-insensitive, trimmed) — duplicates would silently cross-grant access."
  }
  validation {
    condition     = alltrue([for k in keys(var.devs) : can(regex("^[a-z][a-z0-9-]*$", k))])
    error_message = "Every key in devs must be lowercase alphanumeric with optional hyphens, starting with a letter (tag + DNS hostname constraint)."
  }
  validation {
    condition = alltrue(flatten([
      for u in var.devs : [
        for mname in keys(u.machines) : can(regex("^[a-z][a-z0-9-]*$", mname))
      ]
    ]))
    error_message = "Every machine key must be lowercase alphanumeric with optional hyphens, starting with a letter."
  }
  validation {
    condition     = alltrue([for u in var.devs : length(u.machines) > 0])
    error_message = "Each user must declare at least one machine."
  }
  # Flattened-key collision guard (hyphen ambiguity: user 'a-b'+machine 'c'
  # vs user 'a'+machine 'b-c'). merge() in locals.tf silently drops dups —
  # never relax this validation without replacing that merge.
  validation {
    condition = length(distinct(flatten([
      for uname, u in var.devs : [
        for mname in keys(u.machines) : mname == "primary" ? uname : "${uname}-${mname}"
      ]
      ]))) == length(flatten([
      for uname, u in var.devs : [
        for mname in keys(u.machines) : mname == "primary" ? uname : "${uname}-${mname}"
      ]
    ]))
    error_message = "Flattened machine keys must be globally unique ('primary' → bare user key; others → <user>-<machine>). Rename one."
  }
  validation {
    condition = alltrue(flatten([
      for u in var.devs : [
        for m in values(u.machines) :
        m.machine_type == null || !can(regex("^(t2a|c4a|n4a)-", coalesce(m.machine_type, "x")))
      ]
    ]))
    error_message = "machines[*].machine_type overrides must be x86_64 (no t2a-/c4a-/n4a- ARM families) — the pinned image is amd64."
  }
  validation {
    condition = alltrue(flatten([
      for u in var.devs : [
        for m in values(u.machines) :
        m.root_disk_gb == null || (
          coalesce(m.root_disk_gb, 10) >= 10 &&
          coalesce(m.root_disk_gb, 65536) <= 65536 &&
          floor(coalesce(m.root_disk_gb, 10)) == coalesce(m.root_disk_gb, 10)
        )
      ]
    ]))
    error_message = "machines[*].root_disk_gb overrides must be whole numbers between 10 and 65536."
  }
  validation {
    condition = alltrue(flatten([
      for u in var.devs : [
        for m in values(u.machines) :
        m.swap_gib == null || (coalesce(m.swap_gib, 0) >= 0 && coalesce(m.swap_gib, 0) <= 64)
      ]
    ]))
    error_message = "machines[*].swap_gib overrides must be between 0 and 64."
  }
  validation {
    condition = alltrue(flatten([
      for u in var.devs : [
        for m in values(u.machines) :
        startswith(m.zone, "${var.gcp_region}-")
      ]
    ]))
    error_message = "Every machines[*].zone must be a zone of var.gcp_region (single-region by design)."
  }
}

variable "external_machines" {
  description = "Machine-key → owner tailscale_email for machines OUTSIDE this root that must keep tailnet access (this root is the sole ACL writer and renders their tags/rules; it manages no instances or keys for them). Retiring one = delete its entry here and decommission the machine wherever it is managed."
  type        = map(string)
  default     = {}
  validation {
    condition = alltrue([
      for k, e in var.external_machines :
      can(regex("^[a-z][a-z0-9-]*$", k)) && can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", e))
    ])
    error_message = "external_machines keys must be tag-safe (^[a-z][a-z0-9-]*$) and values must be email addresses."
  }
  # Collision with flattened GCP keys would mean one tag with two owners.
  validation {
    condition = length(setintersection(
      toset(keys(var.external_machines)),
      toset(flatten([
        for uname, u in var.devs : [
          for mname in keys(u.machines) : mname == "primary" ? uname : "${uname}-${mname}"
        ]
      ]))
    )) == 0
    error_message = "external_machines keys must not collide with flattened devs machine keys — a collision would render one tag:devbox-<key> for two different machines."
  }
}

variable "manage_tailscale_acl" {
  description = <<-EOT
    Ownership gate for the tailnet ACL. While false (the REQUIRED initial
    state), this root renders ACL locals — inspect the devbox_acl_json
    output to preview the exact policy document — but creates no
    tailscale_acl resource, so a premature apply cannot overwrite your
    existing tailnet policy.

    WARNING: once true, this root is the SOLE writer of the tailnet ACL
    (overwrite_existing_content = true replaces the WHOLE document on every
    apply). This root is designed to own a tailnet dedicated to devboxes;
    if your tailnet carries other policy, merge it into
    gcp/tailscale-acl.tf before enabling. Flip to true exactly once, then
    NEVER back: false would leave the tailnet ACL unmanaged.

    Audit trail: the flip is a tfvars change + apply.
  EOT
  type        = bool
  default     = false
}

variable "tailscale_admin_emails" {
  description = "Tailscale identities of operators with Tailscale-SSH into every devbox (group:devbox-admins). ssh.src cannot be autogroup:admin (rejected by Tailscale policy validation), so admins must be enumerated. At least one is required — the sole ACL writer must never render a policy without an admin SSH path."
  type        = list(string)
  validation {
    condition     = length(var.tailscale_admin_emails) > 0
    error_message = "At least one admin email is required; otherwise no operator can Tailscale-SSH into the fleet."
  }
  validation {
    condition = alltrue([
      for e in var.tailscale_admin_emails :
      can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", e))
    ])
    error_message = "Every entry must look like a valid email address."
  }
  validation {
    condition     = length(distinct([for e in var.tailscale_admin_emails : lower(trimspace(e))])) == length(var.tailscale_admin_emails)
    error_message = "tailscale_admin_emails must be unique (case-insensitive, trimmed)."
  }
}

variable "tailscale_oauth_client_id" {
  description = "Tailscale OAuth client ID (owns tag:devbox-key-minter; scopes auth_keys + policy_file)."
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Secret paired with tailscale_oauth_client_id."
  type        = string
  sensitive   = true
}

variable "tailscale_tailnet" {
  description = "Explicit tailnet identifier. '-' and empty are rejected: the placeholder defaults to whichever tailnet the credential owns, letting wrong-org credentials silently overwrite the wrong ACL."
  type        = string
  validation {
    condition     = var.tailscale_tailnet != "-" && trimspace(var.tailscale_tailnet) != ""
    error_message = "tailscale_tailnet must be an explicit tailnet name; '-' and empty are rejected (fail-closed guard)."
  }
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9.\\-]*\\.[A-Za-z0-9.\\-]+$", var.tailscale_tailnet))
    error_message = "tailscale_tailnet must look like a domain or *.ts.net name."
  }
}

variable "devbox_admins_group" {
  description = "Workspace group holding roles/owner on the project plus the explicit three-grant breakglass set (osAdminLogin, iap.tunnelResourceAccessor, serviceAccountUser on the instance SA). E.g. devbox-admins@example.com."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$", var.devbox_admins_group))
    error_message = "devbox_admins_group must be a group email address."
  }
}

variable "devbox_alert_email" {
  description = "Email for converge-staleness alerts. Empty disables the notification channel + alert policy."
  type        = string
  default     = ""
}

variable "swappiness" {
  description = "Fleet-wide vm.swappiness (manifest-delivered)."
  type        = number
  default     = 60
  validation {
    condition     = var.swappiness >= 0 && var.swappiness <= 200
    error_message = "swappiness must be between 0 and 200."
  }
}

variable "earlyoom_mem_pct" {
  description = "earlyoom -m TERM,KILL available-RAM percentages (manifest-delivered). SIGTERM tier below TERM%, SIGKILL tier below KILL%."
  type        = string
  default     = "8,4"
  validation {
    condition = can(regex("^[0-9]+,[0-9]+$", var.earlyoom_mem_pct)) && try(
      tonumber(split(",", var.earlyoom_mem_pct)[0]) >= 1 &&
      tonumber(split(",", var.earlyoom_mem_pct)[0]) <= 100 &&
      tonumber(split(",", var.earlyoom_mem_pct)[1]) >= 1 &&
      tonumber(split(",", var.earlyoom_mem_pct)[1]) <= tonumber(split(",", var.earlyoom_mem_pct)[0]),
      false
    )
    error_message = "earlyoom_mem_pct must be TERM,KILL integers 1-100 with KILL <= TERM (e.g. 8,4)."
  }
}

variable "earlyoom_swap_pct" {
  description = "earlyoom -s TERM,KILL free-swap percentages (manifest-delivered). Both -m and -s conditions must hold before earlyoom acts."
  type        = string
  default     = "15,8"
  validation {
    condition = can(regex("^[0-9]+,[0-9]+$", var.earlyoom_swap_pct)) && try(
      tonumber(split(",", var.earlyoom_swap_pct)[0]) >= 1 &&
      tonumber(split(",", var.earlyoom_swap_pct)[0]) <= 100 &&
      tonumber(split(",", var.earlyoom_swap_pct)[1]) >= 1 &&
      tonumber(split(",", var.earlyoom_swap_pct)[1]) <= tonumber(split(",", var.earlyoom_swap_pct)[0]),
      false
    )
    error_message = "earlyoom_swap_pct must be TERM,KILL integers 1-100 with KILL <= TERM (e.g. 15,8)."
  }
}

variable "earlyoom_avoid_regex" {
  description = "earlyoom --avoid POSIX ERE: -300 badness bias (NOT exclusion) for matching /proc/<pid>/comm names (15-char truncated). Manifest-delivered. Must contain no whitespace/quotes: the packaged unit expands $EARLYOOM_ARGS unquoted with no quote removal."
  type        = string
  default     = "^(tailscaled|sshd|dockerd|containerd.*|otelopscol|google_guest_ag|google_osconfig|systemd.*|earlyoom)$"
  validation {
    condition     = length(var.earlyoom_avoid_regex) > 0 && !can(regex("[\\s\"']", var.earlyoom_avoid_regex))
    error_message = "earlyoom_avoid_regex must be non-empty with no whitespace or quote characters (unquoted EARLYOOM_ARGS expansion)."
  }
}

variable "earlyoom_enabled" {
  description = "Rollback knob: false makes the next converge disable earlyoom and remove the oomd-demotion drop-ins, restoring stock oomd pressure-kill + swap backstop."
  type        = bool
  default     = true
}

variable "oomd_swap_used_limit" {
  description = "systemd-oomd SwapUsedLimit (manifest-delivered)."
  type        = string
  default     = "95%"
  validation {
    condition     = can(regex("^[0-9]+%$", var.oomd_swap_used_limit))
    error_message = "Must be a percentage like 95%."
  }
}

# ----- AWS federation (all optional: absent → manifest omits the bedrock
# object → devbox-bedrock-config is a no-op; lets plumbing land first) -----

variable "bedrock_role_arn" {
  description = "ARN of the devbox-gcp-workload role from aws-federation/ outputs. Empty until that root is applied and its role_arn output is pasted here."
  type        = string
  default     = ""
  validation {
    condition     = var.bedrock_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/devbox-", var.bedrock_role_arn))
    error_message = "bedrock_role_arn must be empty or an arn:aws:iam::<acct>:role/devbox-* ARN."
  }
}

variable "bedrock_region" {
  description = "AWS region for Bedrock calls (e.g. us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "aws_federation_audience" {
  description = "Dedicated audience string for GCP identity tokens exchanged with AWS STS. Must equal aws-federation/'s var.audience — tokens minted for AWS must not be replayable elsewhere."
  type        = string
  default     = "devbox-fleet-aws-federation"
}

variable "bedrock_model_env" {
  description = "Model/config env delivered as one `env` assignment per key rendered into /usr/local/bin/bclaude, between the AWS_REGION and CLAUDE_CODE_USE_BEDROCK assignments the concern always sets. Must not include a credential selector (AWS_PROFILE, AWS_DEFAULT_PROFILE, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN, AWS_SECURITY_TOKEN, AWS_CREDENTIAL_EXPIRATION, AWS_BEARER_TOKEN_BEDROCK): the wrapper strips those via `env -u` earlier on the same command line, and setting one here would re-set it right back, silently routing Bedrock traffic as the wrong principal or aborting Claude Code's credential chain outright (AWS_PROFILE verified on-box, 2.1.207). devbox-bedrock-config fails loudly if this map contains one."
  type        = map(string)
  default = {
    CLAUDE_CODE_USE_MANTLE   = "1"
    ENABLE_PROMPT_CACHING_1H = "1"
    # Bare model ID: works under Mantle (CLAUDE_CODE_USE_MANTLE=1); without
    # Mantle, on-demand invocation rejects it ("use an inference profile"
    # 400 from Bedrock). The DEFAULT_* pins keep the global.* form. Claude
    # Code strips the [1m] capability suffix before calling Bedrock.
    ANTHROPIC_MODEL               = "anthropic.claude-fable-5[1m]"
    ANTHROPIC_DEFAULT_FABLE_MODEL = "global.anthropic.claude-fable-5[1m]"
    ANTHROPIC_DEFAULT_OPUS_MODEL  = "global.anthropic.claude-opus-5[1m]"
    ANTHROPIC_DEFAULT_HAIKU_MODEL = "global.anthropic.claude-haiku-4-5-20251001-v1:0"
  }
}

variable "bedrock_available_models" {
  description = "Model IDs offered in bclaude's /model picker — rendered as a --settings availableModels JSON on the claude invocation. Empty list omits the flag."
  type        = list(string)
  default = [
    "anthropic.claude-fable-5[1m]",
    "global.anthropic.claude-fable-5[1m]",
    "global.anthropic.claude-opus-5[1m]",
    "global.anthropic.claude-haiku-4-5-20251001-v1:0",
  ]
}

variable "bedrock_codex_config" {
  description = "Codex defaults for the Bedrock provider, rendered sorted as TOML string values into a machine-seeded block that devbox-bedrock-config PREPENDS to ~/.codex/config.toml, after the fixed model_provider = \"amazon-bedrock\" line — so plain codex defaults to Bedrock (no wrapper command). The block is hash-gated: once a dev edits anything inside it, converge leaves the file alone; an unedited block is re-rendered in place. A non-empty map also removes the legacy ~/.codex/bedrock.config.toml. Empty map seeds no block."
  type        = map(string)
  default = {
    model = "openai.gpt-5.6-terra"
    # xhigh is model-dependent; supported by the terra models.
    model_reasoning_effort = "xhigh"
  }
}

variable "codex_mcp_connectors" {
  description = "MCP servers registered in every dev's Codex config at first onboarding, keyed by server name. Delivered via the runtime manifest: the toolchain concern maintains /etc/devbox-connectors.json (removes it when this map is empty) and devbox-onboard merges any missing servers into ~/.codex/config.toml. Empty map: onboarding skips the step. NOT a secret store: url and http_headers land in the GCS manifest, in /etc at 0644, and in every dev's config.toml — never put a token or API key in a header. Codex authentication is per developer (codex mcp login <name>)."
  type = map(object({
    url          = string
    http_headers = optional(map(string), {})
  }))
  default = {}
  validation {
    condition     = alltrue([for name in keys(var.codex_mcp_connectors) : can(regex("^[A-Za-z0-9_-]+$", name))])
    error_message = "Every key in codex_mcp_connectors must be alphanumeric with optional underscores/hyphens: the key becomes the Codex MCP server name and its TOML table name, and anything else (a dot especially) would register the server under the wrong name."
  }
}
