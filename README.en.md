# dsh-deploy

Install DeepSeek Harness as a Linux systemd service.

[![ci](https://github.com/sccyyy/dsh-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/sccyyy/dsh-deploy/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![version](https://img.shields.io/badge/version-1.0.0-blue.svg)](CHANGELOG.md)

English · [简体中文](README.md)

## Contents

- [Quick start](#quick-start)
- [Requirements](#requirements)
- [Configuration](#configuration)
- [Upgrade](#upgrade)
- [Magpie integration](#magpie-integration)
- [Tailscale](#tailscale)
- [Data backup](#data-backup)
- [Uninstall](#uninstall)
- [Development](#development)

## Quick start

```bash
git clone https://github.com/sccyyy/dsh-deploy.git
cd dsh-deploy
chmod +x deploy-dsh.sh
sudo ./deploy-dsh.sh
```

Installs the npm `latest` DSH version and resolves Node.js from its `engines.node` range. DSH runs as user `dsh` on `127.0.0.1:3081`.

Pin versions:

```bash
sudo DSH_VERSION=0.2.2-rc.5 NODE_VERSION=26.13.1 ./deploy-dsh.sh
```

Show the authenticated URL:

```bash
sudo journalctl -u dsh.service -n 100 --no-pager
```

## Requirements

- Linux with systemd; x64 or arm64
- root (`sudo`)
- `curl`, `tar`, `python3`, `sha256sum`
- access to `nodejs.org` and the npm registry
- optional: `xz` (falls back to `.tar.gz`), `flock` (deployment lock)

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `DSH_VERSION` | `latest` | npm dist-tag, concrete version, or `highest` (includes alpha previews) |
| `NODE_VERSION` | `latest` | Match `engines.node`; or pin `x.y.z` |
| `DSH_PORT` | `3081` | Listen port |
| `DSH_SERVICE_USER` | `dsh` | Service account |
| `DSH_UNIT_NAME` | `dsh` | systemd unit name |
| `DSH_DATA_DIR` | `/var/lib/dsh` | Data directory |
| `NODE_ROOT` | `/opt/nodejs` | Node.js install root |
| `DSH_ROOT` | `/opt/dsh` | DSH install root |
| `DSH_NPM_REGISTRY` | `https://registry.npmjs.org` | npm registry (HTTPS) |
| `DSH_STRICT_SANDBOX` | `0` | `ProtectSystem=strict` + `ReadWritePaths` |

`DSH_VERSION=highest` selects the highest semver, including alpha/preview builds; use `latest` or a pinned version in production.

Others: `DSH_WORKSPACE_DIR`, `SYSTEMD_DIR`, `DSH_READY_CODES`, `DSH_SKIP_DATA_PERM`, `DSH_ALLOW_NPM_SCRIPTS`, `DSH_ALLOW_PRIVILEGED_PORT`, `DSH_TAILSCALE_REPLACE`, `DSH_ADOPT_DATA`, `DSH_ADOPT_LEGACY_UNIT`; see the environment variables at the top of `deploy-dsh.sh`.

## Upgrade

```bash
sudo ./deploy-dsh.sh
```

The upgrade stops the service, swaps the program directory, starts it again, and rolls back on failure. [Back up data](#data-backup) first.

**If an older installation is refused:**

| Error | Fix |
|---|---|
| Data directory lacks the ownership marker | Confirm and back up its contents, then add `DSH_ADOPT_DATA=1` |
| The unit was not created by this installer | Confirm it points at the current DSH, then add `DSH_ADOPT_LEGACY_UNIT=1` |

```bash
sudo DSH_ADOPT_DATA=1 ./deploy-dsh.sh
sudo DSH_ADOPT_DATA=1 DSH_ADOPT_LEGACY_UNIT=1 ./deploy-dsh.sh
```

Use these flags only for directories/units you have verified. If `DSH_ROOT` itself lacks the marker, the installer will not adopt it; back it up and move it aside, or choose another `DSH_ROOT`.

## Magpie integration

Magpie discovers DSH by scanning `$DSH_HOME/profiles/*/cordis.patch.yml`. Run Magpie as `dsh` with the same `DSH_HOME`, and put `/opt/dsh/bin` on `PATH`:

```bash
sudo -u dsh env HOME=/var/lib/dsh DSH_HOME=/var/lib/dsh \
  PATH=/var/lib/dsh/.local/bin:/opt/dsh/bin:/opt/nodejs/current/bin:/usr/bin:/bin \
  magpie dsh
```

After the first connection, routes are written to `/var/lib/dsh/profiles/web/cordis.patch.yml` and credentials to the DSH credential file. Do not start Magpie services with `sudo`.

## Tailscale

When Tailscale is connected, the installer tries to expose DSH over HTTPS inside the tailnet via Serve (not Funnel):

- Root path already belongs to another service: skipped by default; set `DSH_TAILSCALE_REPLACE=1` to replace it.
- Root path already points to this instance: left untouched.
- Inspect with `sudo tailscale serve status`.

## Data backup

Data lives in `/var/lib/dsh`, the workspace in `/var/lib/dsh/workspace`, and credentials are mode `0600`.

```bash
sudo tar -C /var/lib -czf /root/dsh-data-$(date +%F).tar.gz dsh
```

Back up before upgrading, migrating, or adopting an old directory.

## Uninstall

```bash
sudo ./deploy-dsh.sh uninstall
sudo ./deploy-dsh.sh uninstall --purge   # remove data too
```

With custom paths, pass the same `NODE_ROOT`, `DSH_ROOT`, `DSH_DATA_DIR`, `DSH_WORKSPACE_DIR`, `SYSTEMD_DIR`, `DSH_UNIT_NAME`, and `DSH_SERVICE_USER` to uninstall.

## Development

```bash
make check      # bash -n + shellcheck + tests
make package    # dist/dsh-deploy-<version>.tar.gz + SHA256SUMS
```

Requires `bash`, `shellcheck` 0.10, and `python3`; `make` is optional.

## License

MIT — see [LICENSE](LICENSE).
