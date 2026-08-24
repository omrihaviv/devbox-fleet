# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
- Codex Superpowers now installs from Codex's preconfigured official
  marketplace (`openai-curated`, github.com/openai/plugins) instead of the
  plugin author's personal repository.

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
