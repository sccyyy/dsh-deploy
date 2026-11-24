# Changelog

## [1.0.0] — 2026-11-23

First public release.

### Added

- Install, upgrade, and uninstall DeepSeek Harness as a Linux systemd service.
- Node.js resolution from `engines.node` (or pin `NODE_VERSION`), with SHA-256 verification.
- Dedicated `dsh` user, permission normalization, systemd sandbox baseline.
- Rollback-safe upgrades and optional Tailscale Serve setup.
- Tests and GitHub Actions CI.

### Security

- npm defaults to `--ignore-scripts --no-audit --no-fund`.
- Data directories `0700`, credentials `0600`, HTTPS-only downloads.
