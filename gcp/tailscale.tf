# Reusable, 24h-TTL, pre-authorized, NON-ephemeral auth keys — one per GCP
# machine (frozen_aws_machines entries keep their externally-managed keys).
#   reusable=true : a bootstrap retry within the TTL re-consumes the same key.
#   expiry=86400  : leaked-key window ≤ one working day.
#   ephemeral=false: /var/lib/tailscale bind-mounts to /data, so node
#                    identity (MagicDNS name) persists across rebuilds.
# replace_triggered_by ties each key to the machine's generation UUID
# (compute.tf) so key + instance always rotate in lockstep.
resource "tailscale_tailnet_key" "devbox" {
  for_each = local.machines

  reusable      = true
  ephemeral     = false
  preauthorized = true
  expiry        = 86400
  tags          = ["tag:devbox-${each.key}"]

  # Expiry must NOT drive replacement. The provider default recreates an
  # invalid reusable key, and because .key renders into the instance's
  # startup-script metadata (compute.tf), that turned every plan >24h after
  # the last apply into a fleet-wide in-place metadata update — one that can
  # never take effect, since `tailscale up --auth-key` lives in the
  # marker-gated PART B and is skipped on an already-bootstrapped box.
  # A key only has to be live when a FRESH instance boots, and both
  # resources replace off the same generation UUID, so every rebuild mints a
  # fresh key in lockstep. Cost of "never": a bootstrap that crashes and
  # does not retry until after the TTL cannot join the tailnet — recover
  # with `apply -replace='tailscale_tailnet_key.devbox["<name>"]'`.
  recreate_if_invalid = "never"

  # Tag-owner declarations must exist before a key for that tag can mint.
  # The gate guarantees the ACL resource exists whenever machines do
  # (variables.tf rejects devs != {} while manage_tailscale_acl = false).
  depends_on = [tailscale_acl.devbox]

  lifecycle {
    replace_triggered_by = [random_uuid.devbox_generation[each.key]]
  }
}
