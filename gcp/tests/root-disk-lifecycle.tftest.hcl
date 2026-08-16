mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/example-test/serviceAccounts/devbox-instance@example-test.iam.gserviceaccount.com"
      email = "devbox-instance@example-test.iam.gserviceaccount.com"
    }
  }
}
mock_provider "random" {}
mock_provider "tailscale" {}

variables {
  gcp_project_id       = "example-test"
  gcp_region           = "us-central1"
  ubuntu_2404_image    = "ubuntu-2404-noble-amd64-v20260707"
  ops_agent_version    = "test"
  manage_tailscale_acl = true

  toolchain = {
    tailscale_version           = "test"
    docker_ce_version           = "test"
    gh_version                  = "test"
    system_node_version         = "test"
    nvm_version                 = "test"
    nvm_install_sha256          = "0000000000000000000000000000000000000000000000000000000000000000"
    node_version                = "test"
    google_chrome_version       = "test"
    chrome_devtools_mcp_version = "test"
    aws_cli_version             = "test"
    aws_cli_install_sha256      = "1111111111111111111111111111111111111111111111111111111111111111"
    claude_installer_sha256     = "2222222222222222222222222222222222222222222222222222222222222222"
    codex_installer_sha256      = "3333333333333333333333333333333333333333333333333333333333333333"
    paseo_cli_version           = "0.0.1"
    paseo_cli_tarball_sha256    = "4444444444444444444444444444444444444444444444444444444444444444"
  }

  tailscale_admin_emails        = ["admin@example.test"]
  tailscale_oauth_client_id     = "test"
  tailscale_oauth_client_secret = "test"
  tailscale_tailnet             = "example.test"
  devbox_admins_group           = "devbox-admins@example.test"

  devs = {
    existing = {
      github_user     = "existing"
      tailscale_email = "existing@example.test"
      machines = {
        primary = {
          zone = "us-central1-a"
        }
      }
    }
  }
}

run "new_machine_uses_120_gb_default" {
  command = plan

  plan_options {
    target = [google_compute_instance.devbox["existing"]]
  }

  assert {
    condition     = google_compute_instance.devbox["existing"].boot_disk[0].initialize_params[0].size == 120
    error_message = "A newly planned machine must use the 120 GB root-disk default."
  }
}

run "create_existing_100_gb_machine" {
  command = apply

  variables {
    devs = {
      existing = {
        github_user     = "existing"
        tailscale_email = "existing@example.test"
        machines = {
          primary = {
            zone         = "us-central1-a"
            root_disk_gb = 100
          }
        }
      }
    }
  }

  plan_options {
    target = [google_compute_instance.devbox["existing"]]
  }

  assert {
    condition     = google_compute_instance.devbox["existing"].boot_disk[0].initialize_params[0].size == 100
    error_message = "The fixture machine must be created with a 100 GB root disk."
  }
}

run "routine_plan_preserves_existing_100_gb_disk" {
  command = plan

  plan_options {
    target = [google_compute_instance.devbox["existing"]]
  }

  assert {
    condition     = google_compute_instance.devbox["existing"].boot_disk[0].initialize_params[0].size == 100
    error_message = "A routine plan must preserve the existing 100 GB root disk despite the 120 GB default."
  }
}

run "generation_rebuild_uses_120_gb_default" {
  command = plan

  variables {
    devs = {
      existing = {
        github_user     = "existing"
        tailscale_email = "existing@example.test"
        machines = {
          primary = {
            zone       = "us-central1-a"
            generation = 2
          }
        }
      }
    }
  }

  plan_options {
    target = [google_compute_instance.devbox["existing"]]
  }

  assert {
    condition     = google_compute_instance.devbox["existing"].boot_disk[0].initialize_params[0].size == 120
    error_message = "A generation-triggered replacement must use the current 120 GB root-disk default."
  }
}

run "reject_placeholder_download_checksums" {
  command = plan

  variables {
    toolchain = {
      tailscale_version           = "test"
      docker_ce_version           = "test"
      gh_version                  = "test"
      system_node_version         = "test"
      nvm_version                 = "test"
      nvm_install_sha256          = "REPLACE_WITH_REAL_SHA"
      node_version                = "test"
      google_chrome_version       = "test"
      chrome_devtools_mcp_version = "test"
      aws_cli_version             = "test"
      aws_cli_install_sha256      = "REPLACE_WITH_REAL_SHA"
      claude_installer_sha256     = "REPLACE_WITH_REAL_SHA"
      codex_installer_sha256      = "REPLACE_WITH_REAL_SHA"
      paseo_cli_version           = "test"
      paseo_cli_tarball_sha256    = "REPLACE_WITH_REAL_SHA"
    }
  }

  expect_failures = [var.toolchain]
}

# The Paseo version pin addresses an exact registry tarball, so the regex must
# be fully anchored: a trailing suffix like "0.4.0junk" would otherwise pass
# validation and reach the fetch URL at converge time.
run "reject_non_exact_paseo_version" {
  command = plan

  variables {
    toolchain = {
      tailscale_version           = "test"
      docker_ce_version           = "test"
      gh_version                  = "test"
      system_node_version         = "test"
      nvm_version                 = "test"
      nvm_install_sha256          = "0000000000000000000000000000000000000000000000000000000000000000"
      node_version                = "test"
      google_chrome_version       = "test"
      chrome_devtools_mcp_version = "test"
      aws_cli_version             = "test"
      aws_cli_install_sha256      = "1111111111111111111111111111111111111111111111111111111111111111"
      claude_installer_sha256     = "2222222222222222222222222222222222222222222222222222222222222222"
      codex_installer_sha256      = "3333333333333333333333333333333333333333333333333333333333333333"
      paseo_cli_version           = "0.4.0junk"
      paseo_cli_tarball_sha256    = "4444444444444444444444444444444444444444444444444444444444444444"
    }
  }

  expect_failures = [var.toolchain]
}

run "reject_machine_outside_configured_region" {
  command = plan

  variables {
    devs = {
      existing = {
        github_user     = "existing"
        tailscale_email = "existing@example.test"
        machines = {
          primary = {
            zone = "europe-west1-b"
          }
        }
      }
    }
  }

  expect_failures = [var.devs]
}
