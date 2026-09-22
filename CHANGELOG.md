# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- Ops Agent convergence now checks the installed package status and version,
  repairs drift even when the version marker is stale, and verifies package
  installation before recording success. Missing or stale markers on a
  correct installation are repaired without reinstalling or restarting it.
  The example configuration now pins Ops Agent 2.70.0.

### Added

- Convergence now runs the vendors' own updaters on every 8h run, on boxes
  where the CLI is already installed: `claude update` and
  `codex update` (`CODEX_NON_INTERACTIVE=1`), each as `dev` under
  `timeout -k 30 300`. Both are non-fatal — a failure logs a `WARN` line to the
  converge journal, leaves the run successful, and the next converge retries.
  The one exception: a Claude update that no longer satisfies the install
  contract invalidates the marker and fails that converge so the normal repair
  path reinstalls. Every Codex release directory except the one `current`
  points at, or one a live `codex` process still runs from, is pruned, so
  `~/.codex/packages/standalone/releases` no longer grows unbounded. The
  version markers are rewritten only when the version changes, so their
  `installed=` timestamp stays the drift trail.
- Opt-in Vercel AI Gateway wrappers: setting `vercel_ai_gateway` publishes
  `vclaude`/`vcodex`, registers **Claude (Vercel Gateway)** and
  **Codex (Vercel Gateway)** in Paseo (live-reloaded), and pre-creates an empty
  0600 `~/.config/vercel-ai-gateway/api-key` for each dev's own key. Plain
  `claude`/`codex` and personal settings are untouched; `null` removes the
  managed wrappers and providers. Dev edits inside the two Paseo entries
  (`enabled`, `models`, `env`, ...) survive re-converges. The admin runbook now
  documents that an unpinned canary is reverted by the next timer run.
- Claude Fable 5.1 (`global.anthropic.claude-fable-5-1[1m]`) as the fleet
  Bedrock default, with Fable 5 retained in bclaude's `/model` picker. The
  runtime now requires Claude Code 2.1.255 or newer and uses the authorized
  Bedrock Runtime inference-profile route instead of Mantle. Paseo versions
  supporting live reload apply this provider configuration without restarting
  the daemon or active agents; older versions retain restart-based updates.
  Package convergence now also defers `paseo.service` in Ubuntu `needrestart`.
- Claude Sonnet 5 (`global.anthropic.claude-sonnet-5[1m]`) in the fleet
  Bedrock defaults: offered in bclaude's `/model` picker and Paseo's
  Claude (Bedrock) provider, and pinned as Claude Code's "sonnet" alias via
  `ANTHROPIC_DEFAULT_SONNET_MODEL`.

### Security

- The Paseo bootstrap install now fetches an exact-version registry tarball
  (`toolchain.paseo_cli_version`) verified against
  `toolchain.paseo_cli_tarball_sha256` instead of `npm install @latest`;
  dev-triggered Paseo updates from the app keep working.
- The Claude Code and Codex installer scripts stay root-owned and
  dev-read-only through execution. Their fetches deliberately trust the
  vendor origins without a sha pin: pins were tried and removed the same day
  because the URLs float, so every legitimate installer update broke the
  repair/bootstrap path until an admin re-pinned.
- Codex Superpowers now installs from Codex's authenticated official
  marketplace (`openai-curated`) instead of the plugin author's personal
  repository. Logged-out bootstrap runs defer this step without failing
  convergence and retry automatically after the developer signs in.

## [0.1.0] — 2026-08-10

Initial public release.

- Terraform root (`gcp/`) — per-dev instances, persistent data disks, daily
  snapshots, Tailscale access with IAP breakglass, monitoring, and
  tailnet ACL management.
- Runtime convergence with canary → promote rollouts.
- First-login developer onboarding (`devbox-onboard`).
- Optional AWS Bedrock federation (`aws-federation/`).
- Public-repo packaging: README, quickstarts, FAQ, agent setup playbook,
  `scripts/preflight` doctor, CI.
