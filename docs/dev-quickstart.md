# Devbox quickstart for developers

You have your own devbox, reached over Tailscale — no public application
ports or SSH by default (your admin keeps an IAP breakglass path). Here's
how to use it.

**Contents**

- [First hour](#first-hour)
- [Daily use](#daily-use)
- [Power features](#power-features)
- [What if my box gets rebuilt?](#what-if-my-box-gets-rebuilt)
- [Reporting issues](#reporting-issues)

## First hour

### First time

1. **Install Tailscale** on your laptop (https://tailscale.com/download) and any phones you use.
2. **Sign in** with your `@your-org.com` email — your admin has already invited you.
3. **SSH to your box:** `ssh dev@<your-name>-devbox`
4. On first login, `devbox-onboard` runs automatically — it asks you to:
   - Authenticate GitHub (`gh auth login --web`)
   - Confirm the git config it derives from your GitHub account
   - Authenticate Claude Code
   - Register your org's Codex MCP connectors (if your admin configured any)
   - Clone the team's standard repos into `~/work/`
   - It also silently wires agent-completion notifications (see "Agent notifications" below)
5. After that, you're done. Future SSH skips onboarding.

### Re-running onboarding

If your admin updates the onboarding script (new step, new tool), run `devbox-onboard` manually — idempotent, every step skips if already done.

Want more repos cloned into `~/work/`? Add them to `~/.devbox-repos` (one `owner/repo` per line) and re-run `devbox-onboard` — repos you already have are left alone.

## Daily use

### Claude Code and Bedrock

**`claude`** is preinstalled and self-updates. It runs on your own personal
account, so run `/login` as usual.

If your admin enabled **Bedrock federation** for the fleet, your box also has
**`bclaude`**: it runs Claude Code on **Amazon Bedrock** through a shared
workload role (the box federates its GCP identity to AWS — no personal AWS
credentials involved). Reach for `bclaude` when you want the shared Bedrock
model; `bdcc` is the same with permission prompts disabled.

If your org also has a Claude.ai plan, its org connectors do not load while
Claude Code is running on Bedrock — they appear in `/mcp` under plain
`claude`, but never in a `bclaude` session.

With federation enabled, Paseo also offers **Claude (Bedrock)** as a managed
agent. It appears only after you restart the managed daemon with
`sudo systemctl restart paseo`—Paseo reads its config once at startup. Paseo's
plain **Claude** entry still uses your personal login, and **Codex** is
already on Bedrock via `~/.codex/config.toml`.

### Mosh and tmux

`mosh dev@<your-name>-devbox` for roaming-tolerant sessions (e.g. iPhone over cellular). Mosh uses UDP; Tailscale tunnels it, so the firewall stays closed to the public internet.

`tmux` is preinstalled for persistent sessions that survive disconnects: start with `tmux new -s work`, detach with `Ctrl-b d`, reattach with `tmux attach -t work`. Pair with mosh for the most resilient setup over flaky networks.

Prefer your session to survive SSH drops automatically? Run `touch ~/.auto-tmux` once — then every login auto-attaches to a persistent `main` session, so a dropped connection reattaches where you left off (handy for long `claude`/`gh` flows). Delete the file to go back to a plain shell.

Your tmux layout also survives **reboots and rebuilds**: every box has [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) installed fleet-wide. Continuum autosaves your sessions/windows/panes/cwd every 15 minutes and restores them automatically when the tmux server starts; save manually with `prefix + Ctrl-s`, restore manually with `prefix + Ctrl-r`. Saves live in `~/.tmux/resurrect/` on your persistent disk. The plugins load from a managed block at the **end** of `~/.tmux.conf` — don't edit inside its markers (it's rewritten centrally), and keep any `status-right` customization *above* it, or continuum's autosave silently stops. Other `@resurrect-*`/`@continuum-*` options are yours to set above the block.

### VS Code for the web

Every devbox includes the `devbox-vscode` launcher. Run:

```bash
devbox-vscode
```

It keeps VS Code bound to loopback on the box and publishes it through tailnet-authenticated Tailscale Serve — `tailscale serve status` on the devbox shows your session's `https://<machine>.<tailnet>.ts.net` URL. Do not add a public GCP firewall rule and do not use Funnel for VS Code.

### iOS

Termius or Blink Shell both work with Tailscale's iOS app. Add `<your-name>-devbox` as a host with user `dev`.

## Power features

### Org MCP connectors for Codex

If your admin configured `codex_mcp_connectors` in the fleet's Terraform,
onboarding pre-registers those remote MCP servers for Codex. Authentication
is per developer and deferred until you want to use a server; no credentials
are stored in the devbox image or fleet configuration. Authenticate with:

```bash
codex mcp login <name>
codex mcp list
```

Codex stores and refreshes its OAuth credentials after you authorize access.

### Paseo

Your box comes with the [Paseo](https://github.com/getpaseo/paseo) CLI preinstalled (at a fleet-pinned version — update it from the Paseo app whenever you want a newer one) and preconfigured for direct Tailscale access. Paseo runs continuously as a boot-enabled systemd service:

```bash
paseo daemon status
sudo systemctl status paseo
sudo systemctl restart paseo
```

Add the daemon as a direct connection in Paseo using `http://<machine>.<tailnet>.ts.net:6767` — print the box's exact DNS name with `tailscale status --json | jq -r '.Self.DNSName'` — or use the address from `tailscale ip -4` with port `6767`. The daemon listens only on the box's Tailscale IPv4 address; Paseo's hosted relay is disabled. There is no separate Paseo password for now, so the existing tailnet policy—your Tailscale identity can reach your machine, and devbox admins can reach every machine—is the access boundary.

The service restarts Paseo if it exits and brings it back after every
reboot, so do not use `paseo daemon stop` for a lasting stop—systemd
intentionally starts it again.

### Agent notifications

Onboarding wires Claude Code (`Stop` + `Notification` hooks) and Codex (`notify`) to `~/bin/tmux-osc-notify.sh`, which broadcasts an OSC 777 escape to every terminal attached to your **current tmux session**. Codex subagent completions are filtered out, so only the completed user-facing turn notifies. If your terminal supports OSC 777 desktop notifications (Ghostty, WezTerm, cmux, …), you get one when an agent finishes a turn or asks for input; terminals that don't (e.g. Termius) silently ignore the bytes. Notes:

- Only fires inside tmux, and only to clients attached at that moment — run agents in a tmux session (pairs well with `~/.auto-tmux`).
- Most terminals suppress the banner while their window is focused; check your notification history if you expected one.
- Want a phone push? Uncomment the `ntfy` line at the bottom of `~/bin/tmux-osc-notify.sh` (read its privacy note first). Your edits to that file survive onboarding re-runs.
- Notification bodies include the agent's last message, which lands in your desktop notification history; swap the `jq` body extraction in the hook commands for a static string if you'd rather not.

### Sharing a dev server publicly (Tailscale Funnel)

Need someone who *isn't* on Tailscale — a teammate, a client — to look at something running on your box (e.g. a Next.js dev server on port 3005)? **Tailscale Funnel** gives you a public HTTPS URL with nothing to install on their end. In a spare shell (or tmux pane):

```bash
tailscale funnel 3005     # prints your public URL, then serves until you stop it
# → https://<your-name>-devbox.<tailnet>.ts.net   (send this; opens in any browser)
```

Press **Ctrl-C** to stop — that cleanly removes just this funnel. Check what's live anytime with `tailscale funnel status` (read-only, no sudo). `dev` is a Tailscale operator, so you can start and stop Funnel without `sudo`.

Prefer not to hold a shell open? `tailscale funnel --bg 3005` runs it in the background. But the only way to stop a backgrounded funnel is `tailscale funnel reset`, which clears the box's **entire** serve/funnel config — including the steered-Chrome `:9222` serve. If you hit that, restore it with `tailscale serve --yes --bg --tcp=9222 tcp://127.0.0.1:9222`.

**The URL is public and unauthenticated** — anyone who has it can reach that port. Only funnel what you mean to share, and stop it when you're done. Funnel serves on public port 443; to expose a second service at the same time, use `--https=8443` or `--https=10000`.

### Chrome on the devbox

You have two Chrome MCP servers registered with Claude Code on the devbox:

| MCP server                  | Chrome process                    | When to ask Claude for it |
|-----------------------------|------------------------------------|---------------------------|
| `chrome-devtools`           | spawned per session, isolated profile, dies when MCP closes | Unauthenticated work — screenshots, scraping public pages, lighthouse runs. Fresh state every time. |
| `chrome-devtools-steered`   | attaches to the long-lived `chrome-steered.service` (CDP on `127.0.0.1:9222`, persistent `--user-data-dir`) | Anything that needs YOUR logged-in session — "post to my Slack", "check our Linear board", "drive this internal dashboard". |

#### Steerable Chrome (log in once, share with the agent)

`chrome-steered.service` runs continuously on the box. You drive it from your laptop; Claude attaches to the same browser to inherit whatever you've logged into.

**To drive it:**

1. Find your devbox's Tailscale IPv4 — from any tailnet-connected device:
   ```bash
   tailscale ip --4 <your-name>-devbox
   ```
   You **must** use the IP, not the MagicDNS hostname — Chrome's CDP rejects hostnames (a DNS-rebinding guard no flag overrides). Tailscale IPs are stable across rebuilds.
2. In your laptop's Chrome, open `chrome://inspect/#devices`, click **Configure...**, add `<that-ip>:9222`, close. No SSH tunnel — the devbox publishes 9222 to the tailnet via `tailscale serve`, and your Tailscale identity already reaches your box.
3. The "Remote Target" list now shows pages open in the steered Chrome (initially `about:blank`). Click **inspect** to open DevTools — the **Sources / Console / Network** panels work as usual, and **More Tools → Remote Devices → screencast** gives you a clickable, typable view of the page. Navigate, log in, complete MFA. Auth state lands in `/home/dev/.local/share/chrome-steered/` on the box and survives instance rebuilds (it's on your persistent disk).

**To hand off to an agent:** ask Claude to "use the steered Chrome" (or name `chrome-devtools-steered` explicitly). The agent opens a fresh tab in the same Chrome process and inherits your cookies/local-storage. When the agent is done, your tab in `chrome://inspect` is unaffected.

**To stop / restart:** `sudo systemctl stop chrome-steered` and `sudo systemctl start chrome-steered` on the box. The service auto-restarts on crash (`Restart=always`).

**Caveats:**
- Only one chrome://inspect viewer at a time gives a clean experience; opening from a second laptop will cause render/input contention on the same page.
- Password autofill from your laptop's keychain does NOT cross the screencast boundary — type, paste, or use email-link login.
- The steered Chrome is a creds aggregator: anyone with shell access as `dev` on the box can drive it. Tailscale identity + your SSH key are the access boundary. Be deliberate about which orgs you log into.

#### Ephemeral Chrome (`chrome-devtools` MCP)

Used by Claude for fire-and-forget Chrome work. No persistent state, no fixed CDP port — Chrome only exists while the MCP call is running. To **watch** what Claude is doing in real time (rare; usually screenshots from Claude are enough):

1. While a Claude MCP session is active, find the chrome listener on the devbox:
   ```bash
   ssh dev@<your-name>-devbox 'sudo ss -ltnp | grep -E "chrome|node"'
   ```
2. Note the loopback port (e.g. `127.0.0.1:NNNNN`).
3. Tunnel that port from your laptop: `ssh -N -L NNNNN:localhost:NNNNN dev@<your-name>-devbox`.
4. Open `chrome://inspect` on your laptop, configure target `localhost:NNNNN`.

If no chrome/node TCP listener is shown, your MCP version is using a unix-domain socket — there's nothing to tunnel; ask Claude for screenshots instead.

### Docker

Docker Engine + Compose plugin are pre-installed. Both `/var/lib/docker` and `/var/lib/containerd` (where Docker ≥ 29's containerd image store keeps image layers) live on your persistent disk, so images and named volumes survive box rebuilds. You're in the `docker` group; no sudo needed. Don't relocate Docker/containerd data roots in `daemon.json` or `config.toml` — the bind mounts already put them on the data volume, and hand-edits are lost on rebuild.

## What if my box gets rebuilt?

Your `/home` (work, auth tokens, git repos, Claude config), Docker images, and Tailscale identity all live on a persistent disk that survives instance rebuilds. After a rebuild, the onboarding marker `~/.devbox-onboarded` is still there, so onboarding does not re-run.

The same applies to resizes: if you need more CPU, RAM, or disk, ask your admin — your box restarts once and everything on your disk stays.

## Reporting issues

Tell your admin. They'll check `/var/log/devbox-startup.log` and
`journalctl -t devbox-converge` on the box (via IAP breakglass if Tailscale
is down).
