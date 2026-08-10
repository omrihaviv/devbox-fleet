# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
