#!/usr/bin/env bash
# Runs every check that does not need root or systemd.
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
rc=0
printf '== syntax ==\n'
if bash -n "$root/deploy-dsh.sh"; then printf 'bash -n: ok\n'; else rc=1; fi
for t in validate resolve-node service-unit contracts; do
  printf '\n== %s ==\n' "$t"
  if ! "$here/$t.sh"; then rc=1; fi
done
printf '\n'
if (( rc == 0 )); then printf 'all tests passed\n'; else printf 'tests failed\n' >&2; fi
exit "$rc"
