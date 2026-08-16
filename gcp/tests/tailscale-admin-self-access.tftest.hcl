mock_provider "google" {}
mock_provider "random" {}
mock_provider "tailscale" {}

variables {
  gcp_project_id       = "example-test"
  ubuntu_2404_image    = "ubuntu-2404-noble-amd64-v20260707"
  ops_agent_version    = "test"
  manage_tailscale_acl = true
  devs                 = {}

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

  external_machines = {
    admin-a = "admin-a@example.test"
    admin-b = "admin-b@example.test"
    member  = "member@example.test"
  }

  tailscale_admin_emails        = ["admin-a@example.test", "admin-b@example.test"]
  tailscale_oauth_client_id     = "test"
  tailscale_oauth_client_secret = "test"
  tailscale_tailnet             = "example.test"
  devbox_admins_group           = "devbox-admins@example.test"
}

run "admins_can_reach_only_their_own_user_devices" {
  command = plan

  assert {
    condition = anytrue([
      for rule in jsondecode(output.devbox_acl_json).acls :
      rule == {
        action = "accept"
        src    = ["group:devbox-admins"]
        dst    = ["autogroup:self:*"]
      }
    ])
    error_message = "The rendered ACL must let each devbox admin reach only devices owned by the same Tailscale identity."
  }

  assert {
    condition = length(try(jsondecode(output.devbox_acl_json).tests, [])) == 6 && alltrue([
      for email in ["admin-a@example.test", "admin-b@example.test"] :
      anytrue([
        for test in try(jsondecode(output.devbox_acl_json).tests, []) :
        test == {
          src    = email
          accept = ["${email}:22"]
        }
      ])
    ])
    error_message = "The rendered policy must test that every configured admin can reach their own user-owned devices and no other configured user can."
  }

  assert {
    condition = alltrue(flatten([
      for admin in ["admin-a@example.test", "admin-b@example.test"] : [
        for other in ["admin-a@example.test", "admin-b@example.test", "member@example.test"] :
        anytrue([
          for test in try(jsondecode(output.devbox_acl_json).tests, []) :
          test == {
            src  = other
            deny = ["${admin}:22"]
          }
        ]) if other != admin
      ]
    ]))
    error_message = "The rendered policy must test that each other configured user is denied access to every admin's user-owned devices."
  }
}

run "empty_fleet_has_no_empty_destinations" {
  command = plan

  variables {
    external_machines = {}
  }

  assert {
    condition = alltrue([
      for rule in jsondecode(output.devbox_acl_json).acls : length(rule.dst) > 0
    ])
    error_message = "An empty fleet must not render packet rules with empty destination lists."
  }

  assert {
    condition = alltrue([
      for rule in jsondecode(output.devbox_acl_json).ssh : length(rule.dst) > 0
    ])
    error_message = "An empty fleet must not render SSH rules with empty destination lists."
  }
}
