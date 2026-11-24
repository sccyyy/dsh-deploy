#!/usr/bin/env bash
# Static contracts for behaviours that cannot be exercised without root/systemd.
# shellcheck disable=SC2016  # needles are literal source excerpts
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
script="$root/deploy-dsh.sh"

pass=0
failed=0
have() {
  local desc="$1" needle="$2"
  if grep -Fq -- "$needle" "$script"; then
    pass=$((pass + 1))
  else
    printf 'FAIL missing %s: %s\n' "$desc" "$needle" >&2
    failed=$((failed + 1))
  fi
}

have "Node checksum fetch" 'SHASUMS256.txt'
have "Node checksum comparison" '"$actual_sha" == "$expected_sha"'
have "npm ignore-scripts" '--ignore-scripts'
have "npm fixed registry" '--registry "$NPM_REGISTRY"'
have "service stop before swap" 'systemctl stop "$SERVICE_NAME.service"'
have "service start after swap" 'systemctl start "$SERVICE_NAME.service"'
have "install lock" 'acquire_lock'
have "sandbox baseline" 'NoNewPrivileges=yes'
have "tailscale conflict guard" 'DSH_TAILSCALE_REPLACE'
have "readiness code set" 'DSH_READY_CODES'
have "port privilege guard" 'DSH_ALLOW_PRIVILEGED_PORT'

# The stopped-service rollback must restart the previous unit.
if grep -Fq 'service_was_active:-0' "$script"; then
  pass=$((pass + 1))
else
  printf 'FAIL rollback does not revive a stopped service\n' >&2
  failed=$((failed + 1))
fi

printf 'contracts: %d passed, %d failed\n' "$pass" "$failed"
(( failed == 0 ))
