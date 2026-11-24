#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly SERVICE_NAME="${DSH_UNIT_NAME:-dsh}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
readonly SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"
readonly DEFAULT_DSH_VERSION="latest"
readonly DSH_MARKER=".deploy-dsh-owned"
readonly DSH_DATA_MARKER=".deploy-dsh-data-owned"
readonly SERVICE_MARKER="# deploy-dsh-installer-owned: sccyyy/dsh-deploy"
DSH_VERSION="${DSH_VERSION:-$DEFAULT_DSH_VERSION}"
# NODE_VERSION=latest (the default) resolves automatically to the newest stable
# Node.js release satisfying the DSH version's engines.node requirement.
# Set NODE_VERSION explicitly (for example, NODE_VERSION=24.22.3) to pin one.
# Resolution failure is fatal: a hardcoded fallback can violate a newer DSH engine range.
NODE_VERSION="${NODE_VERSION:-latest}"
DSH_PORT="${DSH_PORT:-3081}"
NPM_REGISTRY="${DSH_NPM_REGISTRY:-https://registry.npmjs.org}"
NODE_DIST_URL="${NODE_DIST_URL:-https://nodejs.org/dist}"
NPM_REGISTRY="${NPM_REGISTRY%/}"
NODE_DIST_URL="${NODE_DIST_URL%/}"
READY_CODES="${DSH_READY_CODES:-401}"
ALLOW_PRIVILEGED_PORT="${DSH_ALLOW_PRIVILEGED_PORT:-0}"
SKIP_DATA_PERM="${DSH_SKIP_DATA_PERM:-0}"
STRICT_SANDBOX="${DSH_STRICT_SANDBOX:-0}"
ALLOW_NPM_SCRIPTS="${DSH_ALLOW_NPM_SCRIPTS:-0}"
TAILSCALE_REPLACE="${DSH_TAILSCALE_REPLACE:-0}"
NODE_ROOT="${NODE_ROOT:-/opt/nodejs}"
DSH_ROOT="${DSH_ROOT:-/opt/dsh}"
DSH_DATA_DIR="${DSH_DATA_DIR:-/var/lib/dsh}"
DSH_WORKSPACE_DIR="${DSH_WORKSPACE_DIR:-/var/lib/dsh/workspace}"

usage() {
  cat <<'EOF'
Usage: sudo ./deploy-dsh.sh [install|uninstall [--purge]|version|help]

Install DeepSeek Harness as a systemd service. Defaults:
  DSH_VERSION=latest (npm dist-tag)  NODE_VERSION=latest (auto)  DSH_PORT=3081
Set DSH_VERSION explicitly to pin a version, a dist-tag, or "highest" to take
the highest published semver (prereleases included).
NODE_VERSION=latest resolves to the newest stable Node.js release satisfying
the DSH version's engines requirement; resolution failure aborts the install.
Set NODE_VERSION explicitly (for example, 24.22.3) to pin one.
  NODE_ROOT=/opt/nodejs  DSH_ROOT=/opt/dsh  DSH_DATA_DIR=/var/lib/dsh
  DSH_WORKSPACE_DIR=/var/lib/dsh/workspace  DSH_UNIT_NAME=dsh

Advanced: DSH_NPM_REGISTRY, NODE_DIST_URL, DSH_READY_CODES, DSH_ALLOW_PRIVILEGED_PORT,
DSH_SKIP_DATA_PERM, DSH_STRICT_SANDBOX, DSH_ALLOW_NPM_SCRIPTS, DSH_TAILSCALE_REPLACE.
Uninstall preserves DSH_DATA_DIR; pass --purge to remove it.
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_root() { (( EUID == 0 )) || fail 'Run this command as root (for example, with sudo).'; }

# HTTPS-only, bounded, retrying downloads: a redirect must not downgrade to HTTP.
fetch() {
  curl --fail --location --silent --show-error \
    --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 300 \
    "$@"
}

is_mountpoint() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q -- "$path"
    return $?
  fi
  [[ "$(stat -c '%d' -- "$path")" != "$(stat -c '%d' -- "$(dirname -- "$path")")" ]]
}

# Serialize install/uninstall so two runs cannot swap DSH_ROOT under each other.
acquire_lock() {
  local lock="/run/dsh-deploy.lock"
  [[ -d /run ]] || lock="/var/lock/dsh-deploy.lock"
  if ! command -v flock >/dev/null 2>&1; then
    printf 'Warning: flock is unavailable; skipping the deploy lock.\n' >&2
    return 0
  fi
  exec 9>"$lock" || fail "Cannot open lock file: $lock"
  flock -n 9 || fail 'Another deploy-dsh run is already in progress.'
}

valid_config() {
  [[ "$DSH_VERSION" =~ ^[0-9A-Za-z.+_-]+$ ]] || fail 'Invalid DSH_VERSION.'
  [[ "$NODE_VERSION" == "latest" || "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid NODE_VERSION (use x.y.z or latest).'
  [[ "$DSH_PORT" =~ ^[0-9]{1,5}$ ]] || fail 'DSH_PORT must be 1–65535.'
  DSH_PORT=$((10#$DSH_PORT))
  (( DSH_PORT >= 1 && DSH_PORT <= 65535 )) || fail 'DSH_PORT must be 1–65535.'
  if (( DSH_PORT < 1024 )) && [[ "$ALLOW_PRIVILEGED_PORT" != "1" ]]; then
    fail 'DSH_PORT below 1024 requires privileges the dsh service user does not have; set DSH_ALLOW_PRIVILEGED_PORT=1 only if you changed the unit to grant them.'
  fi
  valid_unit_name
  [[ "$NPM_REGISTRY" =~ ^https://[^[:space:]]+$ ]] || fail 'DSH_NPM_REGISTRY must be an https:// URL.'
  [[ "$NODE_DIST_URL" =~ ^https://[^[:space:]]+$ ]] || fail 'NODE_DIST_URL must be an https:// URL.'
  [[ "$READY_CODES" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]] || fail 'DSH_READY_CODES must be space-separated HTTP status codes.'
  valid_paths
}

# Path-shape checks shared by install and uninstall (uninstall must not care
# about port policy or registry URLs).
valid_paths() {
  local path normalized
  [[ "$SYSTEMD_DIR" = /* && "$SYSTEMD_DIR" != / && "$SYSTEMD_DIR" != /etc && "$SYSTEMD_DIR" != /etc/systemd ]] || fail 'SYSTEMD_DIR must be a dedicated absolute unit directory.'
  for path in "$NODE_ROOT" "$DSH_ROOT" "$DSH_DATA_DIR" "$DSH_WORKSPACE_DIR" "$SYSTEMD_DIR"; do
    [[ "$path" = /* ]] || fail 'Install, data, and workspace paths must be absolute.'
    [[ "$path" != *[[:space:]]* ]] || fail 'Install, data, and workspace paths must not contain whitespace (systemd unit syntax).'
    normalized="$(realpath -m -- "$path")"
    [[ "$normalized" == "$path" ]] || fail "Path must be normalized and contain no symlink components: $path"
  done
  [[ "$NODE_ROOT" != / && "$NODE_ROOT" != /opt && "$NODE_ROOT" != /usr && "$NODE_ROOT" != /usr/local ]] || fail 'NODE_ROOT must be a dedicated directory, not a system root.'
  case "$DSH_ROOT" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/usr/local/lib|/var|/var/lib)
      fail 'DSH_ROOT must be a dedicated leaf directory, not a standard system/data root.' ;;
  esac
  case "$DSH_DATA_DIR" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/local|/var|/var/lib)
      fail 'DSH_DATA_DIR must be a dedicated leaf directory, not a standard system/data root.' ;;
  esac
  [[ "$DSH_DATA_DIR" != "$DSH_ROOT" && "$DSH_DATA_DIR" != "$DSH_ROOT"/* && "$DSH_ROOT" != "$DSH_DATA_DIR"/* ]] || fail 'DSH_ROOT and DSH_DATA_DIR must not overlap.'
  [[ "$DSH_WORKSPACE_DIR" != "$DSH_ROOT" && "$DSH_WORKSPACE_DIR" != "$DSH_ROOT"/* ]] || fail 'DSH_WORKSPACE_DIR must not be equal to or under DSH_ROOT.'
  [[ "$DSH_WORKSPACE_DIR" != "$NODE_ROOT" && "$DSH_WORKSPACE_DIR" != "$NODE_ROOT"/* && "$NODE_ROOT" != "$DSH_WORKSPACE_DIR"/* ]] || fail 'NODE_ROOT and DSH_WORKSPACE_DIR must not overlap.'
  [[ "$DSH_DATA_DIR" != "$DSH_WORKSPACE_DIR" && "$DSH_WORKSPACE_DIR" == "$DSH_DATA_DIR"/* ]] || fail 'DSH_WORKSPACE_DIR must be strictly inside DSH_DATA_DIR.' 
  [[ "$NODE_ROOT" != "$DSH_DATA_DIR" && "$NODE_ROOT" != "$DSH_DATA_DIR"/* && "$DSH_DATA_DIR" != "$NODE_ROOT"/* ]] || fail 'NODE_ROOT and DSH_DATA_DIR must not overlap.'
  [[ "$DSH_ROOT" != "$SYSTEMD_DIR" && "$DSH_ROOT" != "$SYSTEMD_DIR"/* && "$SYSTEMD_DIR" != "$DSH_ROOT"/* ]] || fail 'DSH_ROOT and SYSTEMD_DIR must not overlap.'
  [[ "$NODE_ROOT" != "$SYSTEMD_DIR" && "$NODE_ROOT" != "$SYSTEMD_DIR"/* && "$SYSTEMD_DIR" != "$NODE_ROOT"/* ]] || fail 'NODE_ROOT and SYSTEMD_DIR must not overlap.'
  [[ "$DSH_DATA_DIR" != "$SYSTEMD_DIR" && "$DSH_DATA_DIR" != "$SYSTEMD_DIR"/* && "$SYSTEMD_DIR" != "$DSH_DATA_DIR"/* ]] || fail 'DSH_DATA_DIR and SYSTEMD_DIR must not overlap.'
  [[ "$DSH_WORKSPACE_DIR" != "$SYSTEMD_DIR" && "$DSH_WORKSPACE_DIR" != "$SYSTEMD_DIR"/* && "$SYSTEMD_DIR" != "$DSH_WORKSPACE_DIR"/* ]] || fail 'DSH_WORKSPACE_DIR and SYSTEMD_DIR must not overlap.'
  [[ "$DSH_ROOT" != "$NODE_ROOT" && "$DSH_ROOT" != "$NODE_ROOT"/* && "$NODE_ROOT" != "$DSH_ROOT"/* ]] || fail 'DSH_ROOT and NODE_ROOT must not overlap.'
}

valid_unit_name() {
  [[ "$SERVICE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,63}$ ]] || fail 'DSH_UNIT_NAME is not a valid systemd unit name.'
}

service_file_is_managed() {
  [[ -f "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]] || return 1
  grep -Fqx -- "$SERVICE_MARKER" "$SERVICE_FILE" && return 0
  [[ "${DSH_ADOPT_LEGACY_UNIT:-0}" == 1 && -f "$DSH_ROOT/$DSH_MARKER" && ! -L "$DSH_ROOT/$DSH_MARKER" ]] &&
    grep -Fqx -- 'Description=DeepSeek Harness' "$SERVICE_FILE" &&
    grep -Fq -- "ExecStart=${DSH_ROOT}/bin/dsh " "$SERVICE_FILE"
}

assert_no_external_unit() {
  local fragment
  command -v systemctl >/dev/null 2>&1 || return 0
  fragment="$(systemctl show --property=FragmentPath --value "$SERVICE_NAME.service" 2>/dev/null || true)"
  [[ -z "$fragment" || "$fragment" == "$SERVICE_FILE" ]] || fail "Refusing to manage $SERVICE_NAME.service: systemd loads it from $fragment"
}

assert_no_nested_mounts() {
  local root="$1" target targets mountinfo_file="${MOUNTINFO_FILE:-/proc/self/mountinfo}"
  command -v python3 >/dev/null 2>&1 || fail 'python3 is required to check data-directory mount boundaries.'
  [[ -r "$mountinfo_file" ]] || fail "Cannot read mount table: $mountinfo_file"
  targets="$(python3 - "$root" "$mountinfo_file" <<'PY'
import sys
root = sys.argv[1].rstrip("/") or "/"
with open(sys.argv[2], encoding="utf-8") as stream:
    for line in stream:
        fields = line.split()
        raw = fields[4]
        target = raw.replace(r"\040", " ").replace(r"\011", "\t").replace(r"\012", "\n").replace(r"\134", "\\")
        if target == root or target.startswith(root.rstrip("/") + "/"):
            print(target)
PY
)" || fail 'Could not parse the mount table.'
  while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    fail "Refusing recursive data operation across mount boundary: $target"
  done <<< "$targets"
}

validate_data_tree() {
  [[ -d "$DSH_DATA_DIR" && ! -L "$DSH_DATA_DIR" ]] || fail "Refusing data operation: $DSH_DATA_DIR is not a real directory."
  [[ "$(realpath -e -- "$DSH_DATA_DIR")" == "$DSH_DATA_DIR" ]] || fail 'Data directory path must not contain symlink components.'
  [[ -z "$(find "$DSH_DATA_DIR" -xdev -type l -print -quit)" ]] || fail 'Refusing data operation: data filesystem contains symbolic links.'
  assert_no_nested_mounts "$DSH_DATA_DIR"
}

validate_managed_data() {
  validate_data_tree
  [[ -f "$DSH_DATA_DIR/$DSH_DATA_MARKER" && ! -L "$DSH_DATA_DIR/$DSH_DATA_MARKER" ]] || fail "Refusing data operation: $DSH_DATA_DIR lacks the installer ownership marker."
}

adopt_data_for_purge() {
  validate_data_tree
  [[ ! -L "$DSH_DATA_DIR/$DSH_DATA_MARKER" ]] || fail 'Data ownership marker must not be a symbolic link.'
  if [[ ! -e "$DSH_DATA_DIR/$DSH_DATA_MARKER" ]]; then
    [[ "${DSH_ADOPT_DATA:-0}" == 1 ]] || fail "Refusing data operation: $DSH_DATA_DIR lacks the installer ownership marker; set DSH_ADOPT_DATA=1 to explicitly confirm purge."
    : > "$DSH_DATA_DIR/$DSH_DATA_MARKER"
  fi
  validate_managed_data
}

restore_data_metadata() {
  local mode uid gid path
  [[ -n "${data_metadata_backup:-}" && -f "$data_metadata_backup" ]] || return 0
  while IFS= read -r -d '' mode && IFS= read -r -d '' uid && IFS= read -r -d '' gid && IFS= read -r -d '' path; do
    [[ -e "$path" || -L "$path" ]] || continue
    chown --no-dereference "$uid:$gid" "$path" 2>/dev/null || true
    chmod "$mode" "$path" 2>/dev/null || true
  done < "$data_metadata_backup"
}

uninstall() {
  need_root
  acquire_lock
  local purge=0
  [[ "${2:-}" == "--purge" ]] && purge=1
  [[ -z "${2:-}" || "${2:-}" == "--purge" ]] || fail "Unknown uninstall option: $2"
  local arch node_arch node_version_dir current_target link_target service_user="${DSH_SERVICE_USER:-dsh}" group_name="${DSH_SERVICE_USER:-dsh}" serve_port user_owned=0 group_owned=0
  [[ "$service_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail 'Invalid service username.'
  valid_paths
  valid_unit_name

  # Partial purge: the managed install is already gone; only owned data remains.
  # This must run before Node.js version resolution, which needs the current symlink.
  if (( purge )) && [[ ! -e "$DSH_ROOT" && ! -L "$DSH_ROOT" && ! -e "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]]; then
    local remaining_node=""
    if [[ -d "$NODE_ROOT" ]]; then
      remaining_node="$(find "$NODE_ROOT" -maxdepth 1 -mindepth 1 -name 'node-v*' -print -quit 2>/dev/null || true)"
    fi
    if [[ -z "$remaining_node" ]]; then
      if [[ -e "$DSH_DATA_DIR" || -L "$DSH_DATA_DIR" ]]; then
        adopt_data_for_purge
        rm -rf -- "$DSH_DATA_DIR"
      fi
      printf 'Removed remaining managed DSH data at %s; installation directories were already absent.\n' "$DSH_DATA_DIR"
      return 0
    fi
  fi

  case "$(uname -m)" in
    x86_64|amd64) node_arch=x64 ;;
    aarch64|arm64) node_arch=arm64 ;;
    *) fail 'Refusing uninstall on an unsupported architecture; no managed Node.js path can be verified.' ;;
  esac
  if [[ "$NODE_VERSION" == "latest" ]]; then
    # Uninstall targets the installed runtime: read its version from the
    # current symlink instead of resolving a new one.
    link_target="$(readlink -- "$NODE_ROOT/current" 2>/dev/null || true)"
    if [[ "$link_target" =~ node-v([0-9]+\.[0-9]+\.[0-9]+)-linux-(x64|arm64) ]]; then
      NODE_VERSION="${BASH_REMATCH[1]}"
    else
      fail 'Cannot determine the installed Node.js version from NODE_ROOT/current; set NODE_VERSION explicitly (for example, NODE_VERSION=24.22.3).'
    fi
  fi
  [[ "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid NODE_VERSION (use x.y.z or latest).'
  node_version_dir="$NODE_ROOT/node-v${NODE_VERSION}-linux-${node_arch}"
  [[ -d "$DSH_ROOT" && ! -L "$DSH_ROOT" && -f "$DSH_ROOT/$DSH_MARKER" && ! -L "$DSH_ROOT/$DSH_MARKER" ]] || fail "Refusing uninstall: $DSH_ROOT lacks a regular installer ownership marker."
  [[ -e "$DSH_ROOT/bin/dsh" || -L "$DSH_ROOT/bin/dsh" ]] || fail "Refusing uninstall: DSH executable is missing from $DSH_ROOT."
  [[ -x "$DSH_ROOT/bin/dsh" ]] || fail "Refusing uninstall: DSH executable is not executable: $DSH_ROOT/bin/dsh"
  [[ ! -e "$SERVICE_FILE" && ! -L "$SERVICE_FILE" ]] || service_file_is_managed || fail "Refusing uninstall: $SERVICE_FILE is not owned by this installer."
  if [[ -f "$DSH_ROOT/.service-user-owned" && ! -L "$DSH_ROOT/.service-user-owned" ]]; then user_owned=1; fi
  if [[ -f "$DSH_ROOT/.service-group-owned" && ! -L "$DSH_ROOT/.service-group-owned" ]]; then group_owned=1; fi
  [[ ! -L "$NODE_ROOT/current" || "$(readlink -f -- "$NODE_ROOT/current" 2>/dev/null || true)" == "$(readlink -m -- "$node_version_dir")" ]] || fail "Refusing uninstall: $NODE_ROOT/current points to another Node.js installation."
  [[ -d "$node_version_dir" && ! -L "$node_version_dir" && -f "$node_version_dir/$DSH_MARKER" && ! -L "$node_version_dir/$DSH_MARKER" ]] || fail "Refusing uninstall: $node_version_dir lacks a regular installer ownership marker."
  [[ -x "$node_version_dir/bin/node" && -x "$node_version_dir/bin/npm" ]] || fail "Refusing uninstall: managed Node.js runtime is incomplete: $node_version_dir"
  if (( purge )) && [[ -e "$DSH_DATA_DIR" || -L "$DSH_DATA_DIR" ]]; then
    adopt_data_for_purge
  fi
  current_target=""
  if [[ -L "$NODE_ROOT/current" ]]; then current_target="$(readlink -f -- "$NODE_ROOT/current" 2>/dev/null || true)"; fi
  if [[ -f "$DSH_ROOT/.tailscale-serve-owned" ]] && command -v tailscale >/dev/null 2>&1; then
    [[ ! -L "$DSH_ROOT/.tailscale-serve-owned" ]] || fail 'Refusing uninstall: Tailscale ownership marker is a symbolic link.'
    [[ ! -L "$DSH_ROOT/.tailscale-serve-port" ]] || fail 'Refusing uninstall: Tailscale port marker is a symbolic link.'
    serve_port="$DSH_PORT"
    if [[ -r "$DSH_ROOT/.tailscale-serve-port" ]]; then IFS= read -r serve_port < "$DSH_ROOT/.tailscale-serve-port" || true; fi
    if [[ "$serve_port" =~ ^[0-9]+$ ]]; then
      tailscale serve --bg --yes "http://127.0.0.1:${serve_port}" off || printf 'Warning: Tailscale Serve route removal failed; inspect tailscale serve status.\n' >&2
    fi
  elif [[ -f "$DSH_ROOT/.tailscale-serve-owned" ]]; then
    printf 'Warning: Tailscale CLI is unavailable; the DSH Serve route may remain configured.\n' >&2
  fi
  assert_no_external_unit
  if [[ -e "$SERVICE_FILE" || -L "$SERVICE_FILE" ]]; then
    service_file_is_managed || fail "Refusing to remove unit not owned by this installer: $SERVICE_FILE"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl disable --now "$SERVICE_NAME.service" 2>/dev/null || true
      rm -f -- "$SERVICE_FILE"
      systemctl daemon-reload
      systemctl reset-failed "$SERVICE_NAME.service" 2>/dev/null || true
    else
      rm -f -- "$SERVICE_FILE"
    fi
  fi
  is_mountpoint "$DSH_ROOT" && fail "Refusing uninstall: $DSH_ROOT is a mount point."
  rm -rf -- "$DSH_ROOT"
  if (( user_owned )) && id "$service_user" >/dev/null 2>&1; then userdel "$service_user"; fi
  if (( group_owned )) && getent group "$group_name" >/dev/null 2>&1; then
    local group_members
    group_members="$(getent group "$group_name" | cut -d: -f4)"
    if [[ -z "$group_members" ]]; then groupdel "$group_name"; else printf 'Preserving service group %s because it still has members: %s\n' "$group_name" "$group_members" >&2; fi
  fi
  if (( purge )); then
    if [[ -e "$DSH_DATA_DIR" || -L "$DSH_DATA_DIR" ]]; then
      validate_managed_data
      rm -rf -- "$DSH_DATA_DIR"
    fi
  fi
  if [[ -n "$node_arch" ]]; then
    node_version_dir="$NODE_ROOT/node-v${NODE_VERSION}-linux-${node_arch}"
    if [[ "$current_target" == "$node_version_dir" ]]; then rm -f -- "$NODE_ROOT/current"; fi
    is_mountpoint "$node_version_dir" && fail "Refusing uninstall: $node_version_dir is a mount point."
    rm -rf -- "$node_version_dir"
    if [[ -d "$NODE_ROOT" && ! -L "$NODE_ROOT" ]] && [[ -z "$(find "$NODE_ROOT" -mindepth 1 -print -quit)" ]]; then rmdir -- "$NODE_ROOT"; fi
  fi
  if (( purge )); then printf 'Removed DSH service, runtime, and data at %s.\n' "$DSH_DATA_DIR"; else printf 'Removed DSH service and runtime. Preserved data at %s (use --purge to remove it).\n' "$DSH_DATA_DIR"; fi
}

resolve_node_version() {
  # Resolves NODE_VERSION=latest to the newest stable Node.js release that
  # satisfies the DSH version being installed (its engines.node range).
  # A failed resolution aborts the install: falling back to a hardcoded Node
  # version can violate a newer DSH engine range (^24.22.3 || >=26.13.1).
  local resolve_tmp resolved
  command -v curl >/dev/null 2>&1 || fail 'curl is required to resolve NODE_VERSION=latest; set NODE_VERSION=x.y.z to skip resolution.'
  command -v python3 >/dev/null 2>&1 || fail 'python3 is required to resolve NODE_VERSION=latest; set NODE_VERSION=x.y.z to skip resolution.'
  resolve_tmp="$(mktemp -d)" || fail 'Could not create a temporary directory for Node.js version resolution.'
  trap 'rm -rf -- "$resolve_tmp"' RETURN
  fetch -H 'Accept: application/vnd.npm.install-v1+json' "${NPM_REGISTRY}/@deepseek-ai%2Fdsh" -o "$resolve_tmp/dsh.json" \
    || fail "Could not fetch DSH metadata from ${NPM_REGISTRY}; set NODE_VERSION=x.y.z to skip resolution."
  fetch "${NODE_DIST_URL}/index.json" -o "$resolve_tmp/node.json" \
    || fail "Could not fetch the Node.js release index from ${NODE_DIST_URL}; set NODE_VERSION=x.y.z to skip resolution."
  cat >"$resolve_tmp/resolve.py" <<'PYEOF'
import json
import re
import sys


def parse_version(v):
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$", v)
    if not m:
        return None
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
    pre = m.group(4)
    pre_tuple = ()
    if pre:
        for ident in pre.split("."):
            if ident.isdigit():
                pre_tuple += ((0, int(ident), ""),)
            else:
                pre_tuple += ((1, 0, ident),)
    return (major, minor, patch, pre_tuple)


def version_key(v):
    parsed = parse_version(v)
    if parsed is None:
        return None
    major, minor, patch, pre = parsed
    return (major, minor, patch, 1 if not pre else 0, pre)


def expand_comparator(comp):
    """Expand partial comparators such as >=20, ^20.1 and 20.x into full bounds."""
    comp = comp.strip()
    m = re.match(r"^(>=|<=|>|<|=|\^|~)?v?(\d+)(?:\.(\d+|x|X|\*))?(?:\.(\d+|x|X|\*))?$", comp)
    if not m:
        return [comp]
    op = m.group(1) or ""
    major = int(m.group(2))
    minor_raw, patch_raw = m.group(3), m.group(4)
    minor = int(minor_raw) if minor_raw and minor_raw.isdigit() else None
    patch = int(patch_raw) if patch_raw and patch_raw.isdigit() else None
    if minor is not None and patch is not None:
        return [comp]
    if minor is None:
        lo, next_minor, next_major = f"{major}.0.0", f"{major}.1.0", f"{major + 1}.0.0"
    else:
        lo, next_minor, next_major = f"{major}.{minor}.0", f"{major}.{minor + 1}.0", f"{major + 1}.0.0"
    if op in ("", "="):
        return [f">={lo}", f"<{next_minor}"]
    if op in ("^", "~"):
        upper = next_major if (op == "^" and major > 0) or minor is None else next_minor
        return [f">={lo}", f"<{upper}"]
    if op == ">=":
        return [f">={lo}"]
    if op == "<":
        return [f"<{lo}"]
    if op == ">":
        return [f">={next_minor}" if minor is not None else f">={next_major}"]
    if op == "<=":
        return [f"<{next_minor}" if minor is not None else f"<{next_major}"]
    return [comp]


def parse_comparator(comp):
    comp = comp.strip()
    if not comp or comp in ("*", "x", "X"):
        return lambda v: True
    m = re.match(r"^v?(\d+)(?:\.(x|X|\*|\d+))?(?:\.(x|X|\*|\d+))?$", comp)
    if m and ("x" in comp.lower() or comp.count(".") < 2):
        major = int(m.group(1))
        minor = m.group(2)
        if minor is None or str(minor).lower() in ("x", "*"):
            return lambda v, mj=major: (parse_version(v) or (0, 0, 0, ()))[0] == mj
        minor = int(minor)
        patch = m.group(3)
        if patch is None or str(patch).lower() in ("x", "*"):
            def pred(v, mj=major, mn=minor):
                p = parse_version(v)
                return p is not None and p[0] == mj and p[1] == mn
            return pred
    m = re.match(r"^(>=|<=|>|<|=|\^|~)?v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$", comp)
    if not m:
        return None
    op = m.group(1) or ""
    base = "%s.%s.%s" % (m.group(2), m.group(3), m.group(4))
    if m.group(5):
        base += "-" + m.group(5)
    base_key = version_key(base)
    if base_key is None:
        return None
    major, minor, patch = int(m.group(2)), int(m.group(3)), int(m.group(4))

    def ge(v, bk=base_key):
        k = version_key(v)
        return k is not None and k >= bk

    if op in ("", "="):
        return lambda v, bk=base_key: version_key(v) == bk
    if op == ">=":
        return ge
    if op == "<=":
        return lambda v, bk=base_key: (version_key(v) is not None and version_key(v) <= bk)
    if op == ">":
        return lambda v, bk=base_key: (version_key(v) is not None and version_key(v) > bk)
    if op == "<":
        return lambda v, bk=base_key: (version_key(v) is not None and version_key(v) < bk)
    if op == "^":
        if major > 0:
            upper_key = (major + 1, 0, 0, 1, ())
        elif minor > 0:
            upper_key = (0, minor + 1, 0, 1, ())
        else:
            upper_key = (0, 0, patch + 1, 1, ())
        return lambda v, bk=base_key, uk=upper_key: (
            version_key(v) is not None and version_key(v) >= bk and version_key(v) < uk
        )
    if op == "~":
        upper_key = (major, minor + 1, 0, 1, ())
        return lambda v, bk=base_key, uk=upper_key: (
            version_key(v) is not None and version_key(v) >= bk and version_key(v) < uk
        )
    return None


def satisfies(version, range_str):
    if not range_str or not range_str.strip():
        return True
    for group in range_str.split("||"):
        group = group.strip()
        if not group:
            continue
        hm = re.match(r"^(\S+)\s+-\s+(\S+)$", group)
        if hm:
            lo = parse_comparator(">=" + hm.group(1))
            hi = parse_comparator("<=" + hm.group(2))
            if lo is None or hi is None:
                continue
            if lo(version) and hi(version):
                return True
            continue
        preds = []
        ok = True
        for comp in group.split():
            for piece in expand_comparator(comp):
                p = parse_comparator(piece)
                if p is None:
                    ok = False
                    break
                preds.append(p)
            if not ok:
                break
        if ok and all(p(version) for p in preds):
            return True
    return False


def main():
    dsh_path, node_path, dsh_req = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(dsh_path) as f:
        dsh_meta = json.load(f)
    with open(node_path) as f:
        node_index = json.load(f)
    versions = dsh_meta.get("versions", {})
    if dsh_req == "highest":
        valid = [v for v in versions if version_key(v) is not None]
        if not valid:
            print("")
            return
        target = sorted(valid, key=version_key)[-1]
    elif re.match(r"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$", dsh_req):
        target = dsh_req
    else:
        target = dsh_meta.get("dist-tags", {}).get(dsh_req, "")
    if not target or target not in versions:
        print("")
        return
    engines = versions[target].get("engines", {}).get("node", "")
    if not engines:
        print("")
        return
    candidates = []
    for entry in node_index:
        ver = entry.get("version", "")
        if not re.match(r"^v\d+\.\d+\.\d+$", ver):
            continue
        bare = ver[1:]
        if satisfies(bare, engines):
            candidates.append(bare)
    if not candidates:
        print("")
        return
    print(sorted(candidates, key=version_key)[-1])


main()
PYEOF
  resolved="$(python3 "$resolve_tmp/resolve.py" "$resolve_tmp/dsh.json" "$resolve_tmp/node.json" "$DSH_VERSION" 2>/dev/null || true)"
  [[ "$resolved" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "Could not resolve a Node.js version satisfying DSH ${DSH_VERSION}; set NODE_VERSION=x.y.z explicitly."
  NODE_VERSION="$resolved"
  printf 'Resolved Node.js %s for DSH %s.\n' "$NODE_VERSION" "$DSH_VERSION"
}

# Reads `tailscale serve status --json` on stdin and prints the proxy mapped
# at the HTTPS root ("/"), if any. Used to avoid replacing another service's root.
tailscale_root_proxy() {
  python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key, cfg in (data.get("Web") or {}).items():
    if not isinstance(cfg, dict) or not str(key).endswith(":443"):
        continue
    root = (cfg.get("Handlers") or {}).get("/")
    if isinstance(root, dict) and root.get("Proxy"):
        print(root["Proxy"])
        break
'
}

# Render the systemd unit. Kept as a function so tests can assert its content
# without touching systemd or the real filesystem.
service_unit() {
  local exec_args="$1" strict="" protect_home="yes" path
  for path in "$DSH_DATA_DIR" "$DSH_ROOT" "$DSH_WORKSPACE_DIR"; do
    case "$path" in
      /home/*|/var/home/*|/root/*|/run/user/*) protect_home="no" ;;
    esac
  done
  if [[ "$STRICT_SANDBOX" == "1" ]]; then
    strict="ProtectSystem=strict
ReadWritePaths=${DSH_DATA_DIR}"
  fi
  cat <<EOF
[Unit]
${SERVICE_MARKER}
Description=DeepSeek Harness
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${DSH_SERVICE_USER:-dsh}
Group=${DSH_SERVICE_USER:-dsh}
Environment=HOME=${DSH_DATA_DIR}
Environment=DSH_HOME=${DSH_DATA_DIR}
Environment=PATH=${NODE_ROOT}/current/bin:${DSH_ROOT}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
WorkingDirectory=${DSH_WORKSPACE_DIR}
ExecStart=${DSH_ROOT}/bin/dsh ${exec_args}
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=${protect_home}
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallArchitectures=native
${strict}

[Install]
WantedBy=multi-user.target
EOF
}

install_dsh() {
  need_root
  valid_config
  if [[ "$NODE_VERSION" == "latest" ]]; then
    resolve_node_version
  fi
  acquire_lock
  command -v systemctl >/dev/null 2>&1 || fail 'systemd is required.'
  command -v curl >/dev/null 2>&1 || fail 'curl is required.'
  command -v tar >/dev/null 2>&1 || fail 'tar is required.'
  command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required to verify the Node.js download.'
  local arch node_arch tmp node_stage dsh_stage stage_candidate dsh_backup_candidate node_version_dir current_link attempt status tailscale_dns service_args resolved_dsh_version node_created dsh_created service_backup dsh_backup current_link_existed node_root_created old_link_target dsh_root_existed service_file_existed service_changed dsh_parent_created dsh_marker_created node_root_created_initial service_user_created service_group_created marker data_metadata_backup data_dir_created workspace_dir_created data_marker_created service_was_active=0 installed_version existing_root=""
  local service_user="${DSH_SERVICE_USER:-dsh}"
  [[ "$service_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail 'DSH_SERVICE_USER must be a valid system username.'
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) node_arch=x64 ;;
    aarch64|arm64) node_arch=arm64 ;;
    *) fail "Unsupported architecture: $arch (supported: x64, arm64)." ;;
  esac
  node_root_created=0
  if [[ -e "$NODE_ROOT" || -L "$NODE_ROOT" ]]; then [[ -d "$NODE_ROOT" && ! -L "$NODE_ROOT" ]] || fail 'NODE_ROOT must be a real directory.'; else mkdir -p -- "$NODE_ROOT"; node_root_created=1; fi
  node_root_created_initial="$node_root_created"
  service_user_created=0
  service_group_created=0
  dsh_parent_created=0
  if [[ -e "$(dirname -- "$DSH_ROOT")" || -L "$(dirname -- "$DSH_ROOT")" ]]; then [[ -d "$(dirname -- "$DSH_ROOT")" && ! -L "$(dirname -- "$DSH_ROOT")" ]] || fail 'DSH_ROOT parent must be a real directory.'; else mkdir -p -- "$(dirname -- "$DSH_ROOT")"; dsh_parent_created=1; fi
  [[ ! -L "$DSH_ROOT" ]] || fail "DSH_ROOT must not be a symbolic link: $DSH_ROOT"
  dsh_marker_created=0
  if [[ -d "$DSH_ROOT" && ! -e "$DSH_ROOT/$DSH_MARKER" && ! -L "$DSH_ROOT/$DSH_MARKER" ]]; then dsh_marker_created=1; fi
  stage_candidate="$(dirname -- "$DSH_ROOT")/.${DSH_ROOT##*/}.stage-${BASHPID}"
  dsh_backup_candidate="$DSH_ROOT.rollback-${BASHPID}"
  [[ ! -e "$stage_candidate" && ! -L "$stage_candidate" ]] || fail "Staging path already exists: $stage_candidate"
  [[ ! -e "$dsh_backup_candidate" && ! -L "$dsh_backup_candidate" ]] || fail "Rollback path already exists: $dsh_backup_candidate"
  tmp="$(mktemp -d)"
  node_stage=''
  dsh_stage=''
  node_created=0
  dsh_created=0
  service_user_created=0
  service_group_created=0
  data_dir_created=0
  workspace_dir_created=0
  data_marker_created=0
  data_metadata_backup=''
  service_backup=''
  if [[ -L "$SERVICE_FILE" ]]; then fail "Refusing to replace symbolic-link service file: $SERVICE_FILE"; fi
  service_file_existed=0
  service_changed=0
  dsh_backup=''
  dsh_root_existed=0
  current_link_existed=0
  old_link_target=''
  if [[ -L "$NODE_ROOT/current" ]]; then
    current_link_existed=1
    old_link_target="$(readlink -- "$NODE_ROOT/current")"
  fi
  assert_no_external_unit
  if [[ -e "$SERVICE_FILE" || -L "$SERVICE_FILE" ]]; then
    service_file_is_managed || fail "Refusing to replace existing unit not owned by this installer: $SERVICE_FILE"
    service_file_existed=1
    service_backup="$tmp/previous.service"
    cp -a -- "$SERVICE_FILE" "$service_backup"
  fi
  rollback_install() {
    local rc=$?
    trap - EXIT
    set +e
    local restart_old_unit=0
    if (( rc != 0 )); then
      if (( ${service_changed:-0} == 1 && ${service_file_existed:-0} == 0 )); then
        systemctl disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        rm -f -- "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
      elif (( ${service_changed:-0} == 1 )) && [[ -n "${service_backup:-}" && -f "${service_backup:-}" ]]; then
        systemctl disable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        cp -a -- "$service_backup" "$SERVICE_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
        restart_old_unit=1
      fi
      if (( ${service_was_active:-0} == 1 && ${service_changed:-0} == 0 )) && [[ -e "$SERVICE_FILE" ]]; then
        restart_old_unit=1
      fi
      [[ -z "${node_stage:-}" ]] || rm -rf -- "$node_stage"
      [[ -z "${dsh_stage:-}" ]] || rm -rf -- "$dsh_stage"
      if [[ -n "${dsh_backup:-}" && -d "$dsh_backup" ]]; then
        if [[ -d "$DSH_ROOT" && ! -L "$DSH_ROOT" ]]; then rm -rf -- "$DSH_ROOT"; fi
        mv -- "$dsh_backup" "$DSH_ROOT"
      elif (( ${dsh_created:-0} == 1 && ${dsh_root_existed:-0} == 0 )) && [[ -d "$DSH_ROOT" && ! -L "$DSH_ROOT" ]]; then
        rm -rf -- "$DSH_ROOT"
      elif (( ${dsh_marker_created:-0} == 1 )) && [[ -d "$DSH_ROOT" && ! -L "$DSH_ROOT" ]]; then
        rm -f -- "$DSH_ROOT/$DSH_MARKER"
      fi
      if (( ${service_user_created:-0} )) && id "$service_user" >/dev/null 2>&1; then userdel "$service_user" || true; fi
      if (( ${service_group_created:-0} )) && getent group "$service_user" >/dev/null 2>&1; then
        local rollback_group_members
        rollback_group_members="$(getent group "$service_user" | cut -d: -f4)"
        [[ -n "$rollback_group_members" ]] || groupdel "$service_user" || true
      fi
      if (( ${data_dir_created:-0} == 1 )); then
        [[ ! -e "$DSH_DATA_DIR" && ! -L "$DSH_DATA_DIR" ]] || rm -rf -- "$DSH_DATA_DIR"
      else
        restore_data_metadata
        if (( ${data_marker_created:-0} == 1 )); then rm -f -- "$DSH_DATA_DIR/$DSH_DATA_MARKER"; fi
        if (( ${workspace_dir_created:-0} == 1 )) && [[ -d "$DSH_WORKSPACE_DIR" ]]; then rmdir -- "$DSH_WORKSPACE_DIR" 2>/dev/null || true; fi
      fi
      if (( ${node_created:-0} == 1 )) && [[ -d "${node_version_dir:-}" ]]; then rm -rf -- "$node_version_dir"; fi
      if (( ${current_link_existed:-0} == 0 )); then
        rm -f -- "$NODE_ROOT/current"
      else
        ln -sfn -- "$old_link_target" "$NODE_ROOT/current"
      fi
      if (( ${node_root_created_initial:-0} )) && [[ -d "$NODE_ROOT" ]] && [[ -z "$(find "$NODE_ROOT" -mindepth 1 -print -quit)" ]]; then rmdir -- "$NODE_ROOT"; fi
      if (( ${dsh_parent_created:-0} )) && [[ -d "$(dirname -- "$DSH_ROOT")" ]] && [[ -z "$(find "$(dirname -- "$DSH_ROOT")" -mindepth 1 -print -quit)" ]]; then rmdir -- "$(dirname -- "$DSH_ROOT")"; fi
      if (( restart_old_unit )); then
        systemctl enable --now "$SERVICE_NAME.service" >/dev/null 2>&1 || true
      fi
    fi
    [[ -z "${tmp:-}" ]] || rm -rf -- "$tmp"
    exit "$rc"
  }
  trap rollback_install EXIT
  node_version_dir="$NODE_ROOT/node-v${NODE_VERSION}-linux-${node_arch}"
  current_link="$NODE_ROOT/current"
  dsh_root_existed=0
  if [[ -e "$DSH_ROOT" || -L "$DSH_ROOT" ]]; then
    dsh_root_existed=1
    [[ -d "$DSH_ROOT" && ! -L "$DSH_ROOT" && -f "$DSH_ROOT/$DSH_MARKER" && ! -L "$DSH_ROOT/$DSH_MARKER" ]] || fail "$DSH_ROOT exists without a regular installer ownership marker; refusing to use or modify it."
    [[ -x "$DSH_ROOT/bin/dsh" ]] || fail "Existing DSH executable is missing from $DSH_ROOT; refusing upgrade."
  fi
  if [[ -e "$node_version_dir" || -L "$node_version_dir" ]]; then
    [[ -d "$node_version_dir" && ! -L "$node_version_dir" && -f "$node_version_dir/$DSH_MARKER" && ! -L "$node_version_dir/$DSH_MARKER" ]] || fail "$node_version_dir exists without the installer ownership marker; refusing to use or modify it."
    is_mountpoint "$node_version_dir" && fail "Refusing install: $node_version_dir is a mount point."
    [[ -x "$node_version_dir/bin/node" && -x "$node_version_dir/bin/npm" ]] || fail "Owned Node.js runtime is incomplete: $node_version_dir"
  else
    node_stage="$NODE_ROOT/.node-stage-${NODE_VERSION}-${BASHPID}"
    mkdir -m 0755 -- "$node_stage"
    local archive_ext archive_name expected_sha actual_sha
    if command -v xz >/dev/null 2>&1; then archive_ext="tar.xz"; else archive_ext="tar.gz"; fi
    archive_name="node-v${NODE_VERSION}-linux-${node_arch}.${archive_ext}"
    fetch "${NODE_DIST_URL}/v${NODE_VERSION}/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt" \
      || fail "Could not fetch Node.js checksums from ${NODE_DIST_URL}."
    expected_sha="$(awk -v name="$archive_name" '$2 == name { print $1; exit }' "$tmp/SHASUMS256.txt")"
    [[ -n "$expected_sha" ]] || fail "No checksum listed for ${archive_name}."
    fetch "${NODE_DIST_URL}/v${NODE_VERSION}/${archive_name}" -o "$tmp/${archive_name}" \
      || fail "Could not download ${archive_name}."
    actual_sha="$(sha256sum "$tmp/${archive_name}" | awk '{ print $1 }')"
    [[ "$actual_sha" == "$expected_sha" ]] || fail "Node.js archive checksum mismatch for ${archive_name}."
    if [[ "$archive_ext" == "tar.xz" ]]; then tar -xJf "$tmp/${archive_name}" -C "$tmp"; else tar -xzf "$tmp/${archive_name}" -C "$tmp"; fi
    cp -a "$tmp/node-v${NODE_VERSION}-linux-${node_arch}/." "$node_stage/"
    [[ -x "$node_stage/bin/node" && -x "$node_stage/bin/npm" ]] || fail 'Downloaded Node.js archive is incomplete.'
    : > "$node_stage/$DSH_MARKER"
    mv -- "$node_stage" "$node_version_dir"
    node_stage=''
    node_created=1
  fi
  if [[ -e "$current_link" || -L "$current_link" ]]; then
    [[ -L "$current_link" && "$(readlink -f -- "$current_link" 2>/dev/null || true)" == "$(readlink -m -- "$node_version_dir")" ]] || fail "$current_link already exists and is not this install's Node.js version; refusing to replace it. Set NODE_ROOT to a dedicated directory."
  fi
  if [[ "$DSH_VERSION" == "highest" ]]; then
    resolved_dsh_version="$("$node_version_dir/bin/node" -e '
      const { execFileSync } = require("child_process");
      const semver = require(process.argv[1]);
      const versions = JSON.parse(execFileSync(process.argv[2], ["view", "@deepseek-ai/dsh", "versions", "--json", "--registry", process.argv[3]], { encoding: "utf8" }));
      const valid = versions.filter(v => semver.valid(v));
      if (!valid.length) process.exit(2);
      console.log(valid.sort(semver.rcompare)[0]);
    ' "$node_version_dir/lib/node_modules/npm/node_modules/semver" "$node_version_dir/bin/npm" "$NPM_REGISTRY")" || fail 'Could not resolve the highest published DSH version.'
  else
    resolved_dsh_version="$DSH_VERSION"
  fi
  dsh_stage="$stage_candidate"
  [[ ! -e "$dsh_stage" && ! -L "$dsh_stage" ]] || fail "Staging path already exists: $dsh_stage"
  mkdir -m 0755 -- "$dsh_stage"
  : > "$dsh_stage/$DSH_MARKER"
  if [[ -d "$DSH_ROOT" && ! -L "$DSH_ROOT" ]]; then
    for marker in .service-user-owned .service-group-owned .tailscale-serve-owned .tailscale-serve-port; do
      [[ ! -e "$DSH_ROOT/$marker" ]] || cp -a -- "$DSH_ROOT/$marker" "$dsh_stage/$marker"
    done
  fi
  (
    umask 0022
    local -a npm_args=(install --global --prefix "$dsh_stage" --registry "$NPM_REGISTRY" --no-audit --no-fund)
    [[ "$ALLOW_NPM_SCRIPTS" == "1" ]] || npm_args+=(--ignore-scripts)
    npm_args+=("@deepseek-ai/dsh@${resolved_dsh_version}")
    "$node_version_dir/bin/npm" "${npm_args[@]}"
  )
  installed_version="$("$node_version_dir/bin/node" -p "require(process.argv[1]).version" "$dsh_stage/lib/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null || true)"
  [[ -z "$installed_version" ]] || resolved_dsh_version="$installed_version"
  chmod -R a+rX "$dsh_stage"
  chmod 0755 "$dsh_stage/bin" "$dsh_stage/bin/dsh"
  [[ -x "$dsh_stage/bin/dsh" ]] || fail 'npm install did not provide the dsh executable.'
  # Stop any running instance before touching DSH_ROOT so the old process never
  # sees deleted module paths. Rollback restarts it if the install fails early.
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SERVICE_NAME.service"; then
    service_was_active=1
    systemctl stop "$SERVICE_NAME.service" || fail 'Could not stop the running DSH service before upgrade.'
  fi
  if [[ -e "$DSH_ROOT" || -L "$DSH_ROOT" ]]; then
    [[ -d "$DSH_ROOT" && ! -L "$DSH_ROOT" && -f "$DSH_ROOT/$DSH_MARKER" && ! -L "$DSH_ROOT/$DSH_MARKER" ]] || fail "$DSH_ROOT exists without a regular installer ownership marker; refusing to modify it."
    [[ -x "$DSH_ROOT/bin/dsh" ]] || fail "Existing DSH executable is missing from $DSH_ROOT; refusing upgrade."
    is_mountpoint "$DSH_ROOT" && fail "Refusing install: $DSH_ROOT is a mount point."
    dsh_backup="$dsh_backup_candidate"
    mv -- "$DSH_ROOT" "$dsh_backup"
    if ! mv -- "$dsh_stage" "$DSH_ROOT"; then
      mv -- "$dsh_backup" "$DSH_ROOT"
      dsh_backup=''
      fail 'Could not activate staged DSH installation; previous version restored.'
    fi
    dsh_stage=''
  else
    mv -- "$dsh_stage" "$DSH_ROOT"
    dsh_stage=''
    dsh_created=1
  fi
  [[ ! -L "$DSH_DATA_DIR" ]] || fail 'DSH_DATA_DIR must not be a symbolic link.'
  if [[ -e "$DSH_DATA_DIR" ]]; then
    [[ -d "$DSH_DATA_DIR" ]] || fail 'DSH_DATA_DIR exists but is not a directory.'
    [[ "$(realpath -e -- "$DSH_DATA_DIR")" == "$DSH_DATA_DIR" ]] || fail 'DSH_DATA_DIR path must not contain symlink components.'
    [[ -z "$(find "$DSH_DATA_DIR" -xdev -type l -print -quit)" ]] || fail 'DSH_DATA_DIR contains symbolic links on its filesystem; refusing ownership migration.'
    assert_no_nested_mounts "$DSH_DATA_DIR"
    if [[ -e "$DSH_DATA_DIR/$DSH_DATA_MARKER" || -L "$DSH_DATA_DIR/$DSH_DATA_MARKER" ]]; then
      [[ -f "$DSH_DATA_DIR/$DSH_DATA_MARKER" && ! -L "$DSH_DATA_DIR/$DSH_DATA_MARKER" ]] || fail 'Data ownership marker must be a regular file.'
    else
      [[ "${DSH_ADOPT_DATA:-0}" == 1 ]] || fail "Existing data directory lacks $DSH_DATA_MARKER; back it up and re-run with DSH_ADOPT_DATA=1 to adopt it explicitly."
      data_marker_created=1
    fi
  fi
  if [[ ! -e "$DSH_DATA_DIR" ]]; then data_dir_created=1; data_marker_created=1; fi
  if [[ ! -e "$DSH_WORKSPACE_DIR" ]]; then workspace_dir_created=1; fi
  mkdir -p "$DSH_DATA_DIR" "$DSH_WORKSPACE_DIR"
  data_metadata_backup="$tmp/data-metadata.nul"
  : > "$data_metadata_backup"
  if (( ! data_dir_created )); then
    while IFS= read -r -d '' path; do
      printf '%s\0%s\0%s\0%s\0' "$(stat -c '%a' -- "$path")" "$(stat -c '%u' -- "$path")" "$(stat -c '%g' -- "$path")" "$path" >> "$data_metadata_backup"
    done < <(find "$DSH_DATA_DIR" -xdev -print0)
  fi
  if (( data_marker_created )); then : > "$DSH_DATA_DIR/$DSH_DATA_MARKER"; fi
  chmod 0700 "$DSH_DATA_DIR"
  if getent group "$service_user" >/dev/null 2>&1; then
    :
  else
    groupadd --system "$service_user"
    service_group_created=1
    : > "$DSH_ROOT/.service-group-owned"
  fi
  if id "$service_user" >/dev/null 2>&1; then
    [[ "$(id -gn "$service_user")" == "$service_user" ]] || fail "Service user $service_user exists but its primary group is not $service_user."
  else
    useradd --system --gid "$service_user" --home-dir "$DSH_DATA_DIR" --no-create-home --shell /usr/sbin/nologin "$service_user"
    service_user_created=1
    : > "$DSH_ROOT/.service-user-owned"
  fi
  if [[ "$SKIP_DATA_PERM" == "1" ]]; then
    printf 'Warning: DSH_SKIP_DATA_PERM=1; leaving data ownership and permissions unchanged.\n' >&2
  else
    find "$DSH_DATA_DIR" -xdev -type d -exec chmod 0700 {} +
    find "$DSH_DATA_DIR" -xdev -type f -exec chmod go-rwx {} +
    find "$DSH_DATA_DIR" -xdev -type f \( -name '.credentials.yaml' -o -name '*credentials*.yaml' \) -exec chmod 0600 {} +
    find "$DSH_DATA_DIR" -xdev -exec chown --no-dereference "$service_user:$service_user" {} +
    chown --no-dereference "$service_user:$service_user" "$DSH_WORKSPACE_DIR"
  fi
  if [[ ! -e "$current_link" && ! -L "$current_link" ]]; then
    ln -s -- "$node_version_dir" "$current_link"
  else
    ln -sfn -- "$node_version_dir" "$current_link"
  fi
  service_args=(web --host 127.0.0.1 --port "$DSH_PORT" --no-open)
  tailscale_dns=""
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    tailscale_dns="$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' 2>/dev/null || true)"
    if [[ "$tailscale_dns" =~ ^[A-Za-z0-9.-]+$ && "$tailscale_dns" == *.* ]]; then
      existing_root="$(tailscale serve status --json 2>/dev/null | tailscale_root_proxy || true)"
      if [[ -n "$existing_root" && "$existing_root" != "http://127.0.0.1:${DSH_PORT}" && "$TAILSCALE_REPLACE" != "1" ]]; then
        printf 'Tailscale Serve already maps / to %s; skipping Serve setup (set DSH_TAILSCALE_REPLACE=1 to replace it).\n' "$existing_root" >&2
        tailscale_dns=""
      else
        service_args+=(--public-url "https://${tailscale_dns}" --trusted-host "$tailscale_dns")
      fi
    else
      printf 'Could not safely determine this node\047s tailnet DNS name; Serve setup will be skipped.\n' >&2
    fi
  fi
  service_unit "${service_args[*]}" >"$SERVICE_FILE"
  chmod 0644 "$SERVICE_FILE"
  service_changed=1
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME.service"
  systemctl start "$SERVICE_NAME.service"
  for (( attempt = 1; attempt <= 30; attempt++ )); do
    systemctl is-active --quiet "$SERVICE_NAME.service" || break
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 2 "http://127.0.0.1:${DSH_PORT}/" || true)"
    case " $READY_CODES " in *" ${status:-} "*) break ;; esac
    sleep 1
  done
  if ! systemctl is-active --quiet "$SERVICE_NAME.service" || [[ "${status:-}" != 401 ]]; then
    printf 'DSH failed readiness or exited; recent service logs follow:\n' >&2
    journalctl -u "$SERVICE_NAME.service" -n 80 --no-pager >&2 || true
    fail "Service did not remain active and return HTTP ${READY_CODES} within 30 seconds."
  fi
  sleep 2
  if ! systemctl is-active --quiet "$SERVICE_NAME.service"; then
    journalctl -u "$SERVICE_NAME.service" -n 80 --no-pager >&2 || true
    fail 'Service exited after becoming ready.'
  fi
  printf '\nInstalled DSH %s with Node.js %s. Listening on 127.0.0.1:%s.\n' "$resolved_dsh_version" "$NODE_VERSION" "$DSH_PORT"
  printf 'To retrieve the tokenized local URL (keep it private):\n  journalctl -u %s.service -n 100 --no-pager\n' "$SERVICE_NAME"

  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 && [[ "$tailscale_dns" =~ ^[A-Za-z0-9.-]+\.[A-Za-z0-9.-]+$ ]]; then
    if tailscale serve --bg --yes "http://127.0.0.1:${DSH_PORT}"; then
      : > "$DSH_ROOT/.tailscale-serve-owned"
      printf '%s\n' "$DSH_PORT" > "$DSH_ROOT/.tailscale-serve-port"
      printf '\nTailscale Serve enabled. Find the tailnet URL with %s (do not publish it).\n' 'tailscale serve status'
    else
      printf '\nTailscale is connected, but Serve setup failed; inspect %s.\n' 'tailscale serve status' >&2
    fi
  else
    printf '\nTailscale not detected as connected; skipping Serve setup.\n'
  fi
  if [[ -n "$dsh_backup" ]]; then rm -rf -- "$dsh_backup"; dsh_backup=''; fi
  chown --no-dereference "$service_user:$service_user" "$DSH_DATA_DIR/$DSH_DATA_MARKER"
  if (( service_user_created )) && [[ ! -e "$DSH_ROOT/.service-user-owned" ]]; then : > "$DSH_ROOT/.service-user-owned"; fi
  if (( service_group_created )) && [[ ! -e "$DSH_ROOT/.service-group-owned" ]]; then : > "$DSH_ROOT/.service-group-owned"; fi
  rm -rf -- "$tmp"
  node_root_created=0
  trap - EXIT
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-install}" in
    install) install_dsh ;;
    uninstall) uninstall "$@" ;;
    version|-V|--version) printf 'deploy-dsh %s\n' "$SCRIPT_VERSION" ;;
    help|-h|--help) usage ;;
    *) usage >&2; fail "Unknown command: $1" ;;
  esac
fi
