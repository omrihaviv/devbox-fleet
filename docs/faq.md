# FAQ

**What does a devbox cost?** — Roughly the price of an always-on n2-standard-4 VM, two 120 GB persistent disks, and a public IPv4 — price it for your region with the [GCP calculator](https://cloud.google.com/products/calculator), and add a [Tailscale plan](https://tailscale.com/pricing).

**Can I use my existing tailnet?** — You can, but read the warning first: once `manage_tailscale_acl = true`, this repo replaces your tailnet's entire ACL on every apply. Merge your existing policy into `gcp/tailscale-acl.tf` and review the rendered document before opening the gate ([runbook](admin-runbook.md#first-apply)). A dedicated tailnet is simpler.

**What survives a rebuild?** — The per-dev data disk: `/home` (repos, auth tokens, agent config), Docker images/volumes, and the box's Tailscale identity. Rebuilds are routine, not disasters.

**Can devs get different machine sizes?** — Yes. `machine_type`, disk sizes, and swap are per-machine settings in `devs` (fleet defaults otherwise), and a dev can have more than one machine. Changing the machine type later is an in-place stop/restart — not a rebuild — and disks can grow too; either way the dev's data persists ([runbook](admin-runbook.md#routine-operations)).

**How do updates reach the boxes?** — `terraform apply` uploads a candidate; you test it on one canary box; `promote-runtime.sh` moves the fleet pointer; every box converges within ~9 hours. Rollback = promote the previous manifest. Exception: packages configured as `latest` (gh, Chrome, VS Code) track their vendor repos and are not promotion-gated.

**Is my box reachable from the internet?** — No public application ports or SSH by default: SSH only over Tailscale, port 22 open only to Google's IAP range for admin breakglass, and one public UDP port (41641) for WireGuard itself. You can deliberately share a port publicly with Tailscale Funnel — that's a feature, off by default.

**Who can reach my box besides me?** — Fleet admins, on every port, by design (incident response). Every tailnet member can reach dev-preview ports 3000/3005. The [security baseline](admin-runbook.md#security-baseline-accept-or-tighten-before-adding-devs) shows how to tighten both.

**Does AWS/Azure work?** — GCP-only today. The optional `aws-federation/` root exists solely to give boxes AWS Bedrock access without AWS keys.

**How do I pause a box to save money?** — `gcloud compute instances stop <key>-devbox` stops compute and public-IP billing (disks still bill); start it again any time. The box's external IP is ephemeral, so restart assigns a new one — invisible for tailnet SSH, since the box's Tailscale identity persists on its data disk. The fleet is designed always-on, so nothing automates this.

**Something's broken on my box — where do I look?** — Devs: tell your admin. Admins: `/var/log/devbox-startup.log` and `journalctl -t devbox-converge` on the box; IAP breakglass if Tailscale is down ([runbook](admin-runbook.md#breakglass-reserved-for-when-tailscale-is-down)).
