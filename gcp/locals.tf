locals {
  # Flatten users → machines into the flat machine-keyed map every
  # machine-shaped resource iterates. `primary` collapses to the bare user
  # key; other machines become "<user>-<machine>". merge() is safe ONLY
  # because the flattened-key collision guard in variables.tf rejects
  # colliding tfvars — merge() would silently drop a duplicate key.
  machines = merge([
    for uname, u in var.devs : {
      for mname, m in u.machines :
      (mname == "primary" ? uname : "${uname}-${mname}") => {
        owner           = uname
        github_user     = u.github_user
        tailscale_email = u.tailscale_email
        zone            = m.zone
        generation      = m.generation
        machine_type    = coalesce(m.machine_type, var.machine_type)
        root_disk_gb    = coalesce(m.root_disk_gb, var.root_disk_gb)
        data_disk_gb    = coalesce(m.data_disk_gb, var.data_disk_gb)
        swap_gib        = coalesce(m.swap_gib, var.swap_gib)
        extra_repos     = m.extra_repos
      }
    }
  ]...)

  # Union of live GCP machines and the machines in var.external_machines,
  # key → owner email.
  # This is the domain of every ACL construct: the GCP root is the SOLE
  # ACL writer and must render rules for machines it does not manage.
  acl_machines = merge(
    { for k, m in local.machines : k => m.tailscale_email },
    var.external_machines,
  )
}
