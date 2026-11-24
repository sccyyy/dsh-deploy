# dsh-deploy

把 DeepSeek Harness 安装成 Linux systemd 服务。

[![ci](https://github.com/sccyyy/dsh-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/sccyyy/dsh-deploy/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![version](https://img.shields.io/badge/version-1.0.0-blue.svg)](CHANGELOG.md)

简体中文 · [English](README.en.md)

## 目录

- [快速开始](#快速开始)
- [要求](#要求)
- [配置](#配置)
- [升级](#升级)
- [Magpie 接 DSH](#magpie-接-dsh)
- [Tailscale](#tailscale)
- [数据备份](#数据备份)
- [卸载](#卸载)
- [开发](#开发)

## 快速开始

```bash
git clone https://github.com/sccyyy/dsh-deploy.git
cd dsh-deploy
chmod +x deploy-dsh.sh
sudo ./deploy-dsh.sh
```

默认安装 npm `latest` 指向的 DSH 版本，Node.js 自动匹配其 `engines.node` 要求。安装后以用户 `dsh` 运行，监听 `127.0.0.1:3081`。

固定版本：

```bash
sudo DSH_VERSION=0.2.2-rc.5 NODE_VERSION=26.13.1 ./deploy-dsh.sh
```

查看带令牌的访问地址：

```bash
sudo journalctl -u dsh.service -n 100 --no-pager
```

## 要求

- Linux + systemd；x64 或 arm64
- root（`sudo`）
- `curl`、`tar`、`python3`、`sha256sum`
- 可访问 `nodejs.org` 和 npm registry
- 可选：`xz`（缺失时用 `.tar.gz`）、`flock`（安装锁）

## 配置

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DSH_VERSION` | `latest` | npm dist-tag、具体版本，或 `highest`（含 alpha 预览版） |
| `NODE_VERSION` | `latest` | 自动匹配 `engines.node`；可指定 `x.y.z` |
| `DSH_PORT` | `3081` | 监听端口 |
| `DSH_SERVICE_USER` | `dsh` | 服务账户 |
| `DSH_UNIT_NAME` | `dsh` | systemd unit 名称 |
| `DSH_DATA_DIR` | `/var/lib/dsh` | 数据目录 |
| `NODE_ROOT` | `/opt/nodejs` | Node.js 安装目录 |
| `DSH_ROOT` | `/opt/dsh` | DSH 安装目录 |
| `DSH_NPM_REGISTRY` | `https://registry.npmjs.org` | npm registry（HTTPS） |
| `DSH_STRICT_SANDBOX` | `0` | `ProtectSystem=strict` + `ReadWritePaths` |

`DSH_VERSION=highest` 会选最高 semver，包含 alpha/预览版；生产建议用 `latest` 或固定版本。

其余：`DSH_WORKSPACE_DIR`、`SYSTEMD_DIR`、`DSH_READY_CODES`、`DSH_SKIP_DATA_PERM`、`DSH_ALLOW_NPM_SCRIPTS`、`DSH_ALLOW_PRIVILEGED_PORT`、`DSH_TAILSCALE_REPLACE`、`DSH_ADOPT_DATA`、`DSH_ADOPT_LEGACY_UNIT`，见脚本顶部的环境变量定义。

## 升级

```bash
sudo ./deploy-dsh.sh
```

升级会先停服务、替换程序目录、再启动；失败自动回滚。升级前先[备份数据](#数据备份)。

**从旧安装升级被拒绝时：**

| 报错 | 处理 |
|---|---|
| 数据目录缺少所有权标记 | 确认内容并备份后，加 `DSH_ADOPT_DATA=1` |
| unit 不是本安装器创建的 | 确认 unit 指向当前 DSH，加 `DSH_ADOPT_LEGACY_UNIT=1` |

```bash
sudo DSH_ADOPT_DATA=1 ./deploy-dsh.sh
sudo DSH_ADOPT_DATA=1 DSH_ADOPT_LEGACY_UNIT=1 ./deploy-dsh.sh
```

这两个开关只用于接管你确认过的旧目录/旧 unit，不要无条件加。若 `DSH_ROOT` 本身缺少标记，安装器不会接管；请备份后移走，或换一个 `DSH_ROOT`。

## Magpie 接 DSH

Magpie 扫描 `$DSH_HOME/profiles/*/cordis.patch.yml` 发现 DSH。让 Magpie 以 `dsh` 用户运行，`DSH_HOME` 与 DSH 一致，`PATH` 包含 `/opt/dsh/bin`：

```bash
sudo -u dsh env HOME=/var/lib/dsh DSH_HOME=/var/lib/dsh \
  PATH=/var/lib/dsh/.local/bin:/opt/dsh/bin:/opt/nodejs/current/bin:/usr/bin:/bin \
  magpie dsh
```

首次连接后，路由写入 `/var/lib/dsh/profiles/web/cordis.patch.yml`，凭据存入 DSH 凭据文件。不要把 `sudo` 用于启动 Magpie 服务。

## Tailscale

检测到 Tailscale 时，安装器会尝试通过 Serve 提供 tailnet 内的 HTTPS 入口（不是 Funnel）：

- 根路径已属于其他服务：默认跳过，设 `DSH_TAILSCALE_REPLACE=1` 才替换；
- 根路径已指向本实例：保持不动；
- 查看：`sudo tailscale serve status`。

## 数据备份

数据目录 `/var/lib/dsh`，工作区 `/var/lib/dsh/workspace`，凭据文件权限 `0600`。

```bash
sudo tar -C /var/lib -czf /root/dsh-data-$(date +%F).tar.gz dsh
```

升级、迁移、接管旧目录前都先备份。

## 卸载

```bash
sudo ./deploy-dsh.sh uninstall
sudo ./deploy-dsh.sh uninstall --purge   # 连数据一起删除
```

自定义路径时，卸载命令需带相同的 `NODE_ROOT`、`DSH_ROOT`、`DSH_DATA_DIR`、`DSH_WORKSPACE_DIR`、`SYSTEMD_DIR`、`DSH_UNIT_NAME`、`DSH_SERVICE_USER`。

## 开发

```bash
make check      # bash -n + shellcheck + tests
make package    # dist/dsh-deploy-<version>.tar.gz + SHA256SUMS
```

需要 `bash`、`shellcheck` 0.10、`python3`；`make` 可选。

## 许可证

MIT，见 [LICENSE](LICENSE)。
