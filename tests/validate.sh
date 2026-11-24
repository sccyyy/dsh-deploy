#!/usr/bin/env bash
# valid_config() regression tests. Sourcing the installer is supported: its
# main dispatch only runs when the file is executed directly.
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
# shellcheck source=/dev/null
source "$root/deploy-dsh.sh"

pass=0
failed=0
with_env() {
  local -a pairs=("$@")
  ( export "${pairs[@]}"; valid_config )
}
expect_ok() {
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    printf 'FAIL (expected ok): %s\n' "$desc" >&2
    failed=$((failed + 1))
  fi
}
expect_fail() {
  local desc="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then
    printf 'FAIL (expected rejection): %s\n' "$desc" >&2
    failed=$((failed + 1))
  else
    pass=$((pass + 1))
  fi
}

expect_ok "defaults" valid_config
expect_ok "NODE_VERSION=latest (uninstall default)" with_env NODE_VERSION=latest
expect_ok "port 1024" with_env DSH_PORT=1024
expect_fail "port 80 without opt-in" with_env DSH_PORT=80
expect_ok "port 80 with opt-in" with_env DSH_PORT=80 ALLOW_PRIVILEGED_PORT=1
# shellcheck disable=SC2016 # the inner script must see literal $1
expect_fail "unit name with slash" bash -c 'DSH_UNIT_NAME="bad/name"; source "$1"; valid_config' _ "$root/deploy-dsh.sh"
expect_fail "plain-http registry" with_env NPM_REGISTRY=http://registry.example
expect_fail "bad ready codes" with_env READY_CODES=200,301
expect_fail "workspace outside data dir" with_env DSH_WORKSPACE_DIR=/srv/work
expect_fail "data root overlap" with_env DSH_DATA_DIR=/opt/dsh/data
expect_fail "whitespace in path" with_env DSH_WORKSPACE_DIR="/var/lib/dsh/work space"
expect_fail "empty NODE_VERSION" with_env NODE_VERSION=

# Regression: uninstall must resolve NODE_VERSION from the current symlink
# before valid_config, otherwise the default "latest" reaches node_version_dir.
resolve_line="$(awk '/^uninstall\(\)/ { inside = 1 } inside && /BASH_REMATCH\[1\]/ { print NR; exit }' "$root/deploy-dsh.sh")"
valid_line="$(awk '/^uninstall\(\)/ { inside = 1 } inside && /^[[:space:]]*valid_config$/ { print NR; exit }' "$root/deploy-dsh.sh")"
if [[ -n "$resolve_line" && -n "$valid_line" && "$resolve_line" -lt "$valid_line" ]]; then
  pass=$((pass + 1))
else
  printf 'FAIL uninstall must resolve NODE_VERSION before valid_config (resolve=%s valid=%s)\n' "${resolve_line:-none}" "${valid_line:-none}" >&2
  failed=$((failed + 1))
fi

printf 'validate: %d passed, %d failed\n' "$pass" "$failed"
(( failed == 0 ))
