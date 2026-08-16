# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security

- Pinned the previously unverified fetch-and-execute paths in
  `devbox-toolchain`: the Claude Code and Codex installer scripts are now
  verified against org sha256 pins (`toolchain.claude_installer_sha256`,
  `toolchain.codex_installer_sha256`) before running — and stay root-owned
  and dev-read-only through execution — and the Paseo bootstrap
  install fetches an exact-version registry tarball verified against
  `toolchain.paseo_cli_tarball_sha256` instead of `npm install @latest`. The
  agent CLIs' own self-update channels intentionally stay open; Paseo updates
  remain available on demand from the Paseo app.
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
