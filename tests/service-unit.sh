#!/usr/bin/env bash
# Asserts the generated systemd unit keeps its contract and hardening baseline.
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
# shellcheck source=/dev/null
source "$root/deploy-dsh.sh"

unit="$(service_unit "web --host 127.0.0.1 --port 3081 --no-open")"
pass=0
failed=0
check() {
  local desc="$1" needle="$2"
  if grep -Fq -- "$needle" <<<"$unit"; then
    pass=$((pass + 1))
  else
    printf 'FAIL missing %s: %s\n' "$desc" "$needle" >&2
    failed=$((failed + 1))
  fi
}
check "exec" "ExecStart=/opt/dsh/bin/dsh web --host 127.0.0.1 --port 3081 --no-open"
check "user" "User=dsh"
check "no-new-privileges" "NoNewPrivileges=yes"
check "private-tmp" "PrivateTmp=yes"
check "protect-home" "ProtectHome=yes"
check "address families" "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK"
check "umask" "UMask=0077"
if grep -Fq "ProtectSystem=strict" <<<"$unit"; then
  printf 'FAIL strict sandbox must be opt-in\n' >&2
  failed=$((failed + 1))
else
  pass=$((pass + 1))
fi

strict_unit="$(STRICT_SANDBOX=1 service_unit "web")"
if grep -Fq "ProtectSystem=strict" <<<"$strict_unit" && grep -Fq "ReadWritePaths=/var/lib/dsh" <<<"$strict_unit"; then
  pass=$((pass + 1))
else
  printf 'FAIL strict sandbox lines missing\n' >&2
  failed=$((failed + 1))
fi

home_unit="$(DSH_DATA_DIR=/home/someone/.dsh DSH_WORKSPACE_DIR=/home/someone/.dsh/workspace service_unit "web")"
if grep -Fq "ProtectHome=no" <<<"$home_unit"; then
  pass=$((pass + 1))
else
  printf 'FAIL ProtectHome must be disabled for data under /home\n' >&2
  failed=$((failed + 1))
fi

printf 'service-unit: %d passed, %d failed\n' "$pass" "$failed"
(( failed == 0 ))
