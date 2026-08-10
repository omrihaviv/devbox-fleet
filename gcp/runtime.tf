locals {
  # The converge bundle: GCP variants + shared (cloud-agnostic) scripts.
  # devbox-aws-creds is delivered/installed but never dispatched as a
  # concern — the AWS CLI invokes it via credential_process and Claude
  # Code invokes it via the awsCredentialExport managed setting.
  devbox_runtime_script_paths = {
    "devbox-converge"       = "${path.module}/../scripts/gcp/devbox-converge"
    "devbox-memory-hotfix"  = "${path.module}/../scripts/devbox-memory-hotfix"
    "devbox-toolchain"      = "${path.module}/../scripts/devbox-toolchain"
    "devbox-observability"  = "${path.module}/../scripts/gcp/devbox-observability"
    "devbox-bedrock-config" = "${path.module}/../scripts/gcp/devbox-bedrock-config"
    "devbox-aws-creds"      = "${path.module}/../scripts/gcp/devbox-aws-creds"
  }

  devbox_runtime_script_sha256 = {
    for name, path in local.devbox_runtime_script_paths : name => filesha256(path)
  }

  # Fleet env delivered to every concern via the manifest. Per-machine
  # values (swap) ride instance metadata instead — see compute.tf.
  runtime_manifest_env = {
    DEVBOX_SWAP_SIZE_GIB               = tostring(var.swap_gib) # fleet default; metadata overrides
    DEVBOX_SWAPPINESS                  = tostring(var.swappiness)
    DEVBOX_EARLYOOM_ENABLED            = tostring(var.earlyoom_enabled)
    DEVBOX_EARLYOOM_MEM_PCT            = var.earlyoom_mem_pct
    DEVBOX_EARLYOOM_SWAP_PCT           = var.earlyoom_swap_pct
    DEVBOX_EARLYOOM_AVOID_REGEX        = var.earlyoom_avoid_regex
    DEVBOX_OOMD_SWAP_USED_LIMIT        = var.oomd_swap_used_limit
    DEVBOX_OPS_AGENT_VERSION           = var.ops_agent_version
    DEVBOX_TAILSCALE_VERSION           = var.toolchain.tailscale_version
    DEVBOX_DOCKER_CE_VERSION           = var.toolchain.docker_ce_version
    DEVBOX_GH_VERSION                  = var.toolchain.gh_version
    DEVBOX_SYSTEM_NODE_VERSION         = var.toolchain.system_node_version
    DEVBOX_NVM_VERSION                 = var.toolchain.nvm_version
    DEVBOX_NVM_INSTALL_SHA256          = var.toolchain.nvm_install_sha256
    DEVBOX_NODE_VERSION                = var.toolchain.node_version
    DEVBOX_GOOGLE_CHROME_VERSION       = var.toolchain.google_chrome_version
    DEVBOX_CHROME_DEVTOOLS_MCP_VERSION = var.toolchain.chrome_devtools_mcp_version
    DEVBOX_VSCODE_VERSION              = var.toolchain.vscode_version
    DEVBOX_AWS_CLI_VERSION             = var.toolchain.aws_cli_version
    DEVBOX_AWS_CLI_INSTALL_SHA256      = var.toolchain.aws_cli_install_sha256
    DEVBOX_TMUX_RESURRECT_COMMIT       = var.toolchain.tmux_resurrect_commit
    DEVBOX_TMUX_CONTINUUM_COMMIT       = var.toolchain.tmux_continuum_commit
    DEVBOX_CODEX_MCP_CONNECTORS        = jsonencode(var.codex_mcp_connectors)
  }

  # Bedrock object is OPTIONAL: empty role ARN → key omitted entirely →
  # devbox-bedrock-config no-ops (plumbing lands before federation).
  runtime_manifest = merge(
    {
      schema = 1
      scripts = {
        for name, _ in local.devbox_runtime_script_paths : name => {
          key    = "runtime/${name}/${local.devbox_runtime_script_sha256[name]}"
          sha256 = local.devbox_runtime_script_sha256[name]
        }
      }
      env = local.runtime_manifest_env
    },
    var.bedrock_role_arn == "" ? {} : {
      bedrock = {
        role_arn         = var.bedrock_role_arn
        region           = var.bedrock_region
        audience         = var.aws_federation_audience
        model_env        = var.bedrock_model_env
        available_models = var.bedrock_available_models
        codex_config     = var.bedrock_codex_config
      }
    }
  )

  runtime_manifest_json   = jsonencode(local.runtime_manifest)
  runtime_manifest_sha256 = sha256(local.runtime_manifest_json)
}

resource "google_storage_bucket" "devbox_runtime" {
  name     = "${var.gcp_project_id}-devbox-runtime"
  location = var.gcp_region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  labels = {
    devbox = "true"
  }
}

# Instance SA reads the bundle — scoped to THIS bucket only.
resource "google_storage_bucket_iam_member" "instance_object_viewer" {
  bucket = google_storage_bucket.devbox_runtime.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.devbox_instance.email}"
}

resource "google_storage_bucket_object" "devbox_runtime_script" {
  for_each = local.devbox_runtime_script_paths

  bucket          = google_storage_bucket.devbox_runtime.name
  name            = "runtime/${each.key}/${local.devbox_runtime_script_sha256[each.key]}"
  source          = each.value
  content_type    = "text/x-shellscript"
  deletion_policy = "ABANDON"
}

# Content-addressed CANDIDATE manifest. terraform apply never touches the
# fleet pointer runtime/manifest.json — promotion is an explicit admin
# action (scripts/gcp/promote-runtime.sh) after the canary passes.
resource "google_storage_bucket_object" "runtime_manifest_candidate" {
  bucket          = google_storage_bucket.devbox_runtime.name
  name            = "runtime/manifest/${local.runtime_manifest_sha256}.json"
  content         = local.runtime_manifest_json
  content_type    = "application/json"
  deletion_policy = "ABANDON"

  depends_on = [google_storage_bucket_object.devbox_runtime_script]
}
