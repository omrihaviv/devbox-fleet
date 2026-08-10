# Tailnet ACL rendered from local.acl_machines — the UNION of live GCP machines
# and machines outside this root (var.frozen_aws_machines). This root is the
# SOLE writer of the tailnet policy document (overwrite_existing_content = true
# rewrites the WHOLE document each apply).
#
# OWNERSHIP GATE: count = var.manage_tailscale_acl ? 1 : 0. While false,
# the locals below still render a machine-free skeleton, but no resource
# exists — a premature apply cannot overwrite an existing tailnet policy.
# Inspect the planned output with the pending gate-open machine set for the
# exact document before applying that same saved plan.
#
# Structure: per-machine tags owned by autogroup:admin +
# tag:devbox-key-minter (the OAuth client's delegating tag — OAuth clients
# don't support tag wildcards); per-machine packet + SSH rules (owner email →
# own machines, user `dev`); group:devbox-admins reaches every devbox and each
# admin's own user-owned devices; team preview ports; funnel node-attrs
# (autogroup:member EXCLUDES tagged nodes, so devbox tags are listed
# explicitly).

locals {
  tag_owners = merge(
    {
      for k, _ in local.acl_machines :
      "tag:devbox-${k}" => ["autogroup:admin", "tag:devbox-key-minter"]
    },
    {
      "tag:devbox-key-minter" = ["autogroup:admin", "tag:devbox-key-minter"]
    },
  )

  per_machine_acl_rules = [
    for k, email in local.acl_machines : {
      action = "accept"
      src    = [email]
      dst    = ["tag:devbox-${k}:*"]
    }
  ]

  admin_acl_rule = {
    action = "accept"
    src    = ["group:devbox-admins"]
    dst    = [for k, _ in local.acl_machines : "tag:devbox-${k}:*"]
  }

  admin_self_acl_rule = {
    action = "accept"
    src    = ["group:devbox-admins"]
    dst    = ["autogroup:self:*"]
  }

  shared_dev_ports_rule = {
    action = "accept"
    src    = ["autogroup:member"]
    dst    = [for k, _ in local.acl_machines : "tag:devbox-${k}:3000,3005"]
  }

  acl_rules = concat(
    local.per_machine_acl_rules,
    length(local.acl_machines) > 0 ? [local.admin_acl_rule] : [],
    [local.admin_self_acl_rule],
    length(local.acl_machines) > 0 ? [local.shared_dev_ports_rule] : [],
  )

  admin_self_acl_tests = flatten([
    for admin_email in var.tailscale_admin_emails : concat(
      [{
        src    = admin_email
        accept = ["${admin_email}:22"]
      }],
      [
        for other_email in distinct(values(local.acl_machines)) : {
          src  = other_email
          deny = ["${admin_email}:22"]
        } if other_email != admin_email
      ],
    )
  ])

  funnel_node_attrs = [
    {
      target = concat(["autogroup:member"], [for k, _ in local.acl_machines : "tag:devbox-${k}"])
      attr   = ["funnel"]
    }
  ]

  per_machine_ssh_rules = [
    for k, email in local.acl_machines : {
      action = "accept"
      src    = [email]
      dst    = ["tag:devbox-${k}"]
      users  = ["dev"]
    }
  ]

  admin_ssh_rule = {
    action = "accept"
    src    = ["group:devbox-admins"]
    dst    = [for k, _ in local.acl_machines : "tag:devbox-${k}"]
    users  = ["dev"]
  }

  ssh_rules = concat(
    local.per_machine_ssh_rules,
    length(local.acl_machines) > 0 ? [local.admin_ssh_rule] : [],
  )

  devbox_acl_document = {
    groups = {
      "group:devbox-admins" = var.tailscale_admin_emails
    }
    tagOwners = local.tag_owners
    acls      = local.acl_rules
    nodeAttrs = local.funnel_node_attrs
    ssh       = local.ssh_rules
    tests     = local.admin_self_acl_tests
  }

  devbox_acl_json = jsonencode(local.devbox_acl_document)
}

resource "tailscale_acl" "devbox" {
  count = var.manage_tailscale_acl ? 1 : 0

  overwrite_existing_content = true
  acl                        = local.devbox_acl_json
}
