#!/usr/bin/env bash
# Exercises the embedded Node.js version resolver against fixture metadata.
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

awk '/<<.PYEOF.$/ { capture = 1; next } /^PYEOF$/ { capture = 0 } capture' \
  "$root/deploy-dsh.sh" > "$work/resolve.py"
[[ -s "$work/resolve.py" ]] || { printf 'could not extract resolver\n' >&2; exit 1; }

cat > "$work/dsh.json" <<'JSON'
{
  "dist-tags": { "latest": "1.2.0", "next": "9.0.0-alpha.2" },
  "versions": {
    "1.0.0": { "engines": { "node": ">=20" } },
    "1.2.0": { "engines": { "node": "^24.22.3 || >=26.13.1" } },
    "9.0.0-alpha.2": { "engines": { "node": ">=24" } }
  }
}
JSON
cat > "$work/node.json" <<'JSON'
[
  { "version": "v20.19.0" },
  { "version": "v24.9.0" },
  { "version": "v24.22.3" },
  { "version": "v26.13.1" },
  { "version": "v27.0.0-alpha.1" }
]
JSON

run() { python3 "$work/resolve.py" "$work/dsh.json" "$work/node.json" "$1"; }
pass=0
failed=0
check() {
  local desc="$1" want="$2" got="$3"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
  else
    printf 'FAIL %s: want %q got %q\n' "$desc" "$want" "$got" >&2
    failed=$((failed + 1))
  fi
}

check "latest dist-tag" "26.13.1" "$(run latest)"
check "pinned 1.0.0" "26.13.1" "$(run 1.0.0)"
check "highest includes prerelease" "26.13.1" "$(run highest)"
check "unknown tag resolves to nothing" "" "$(run does-not-exist)"
check "pinned 1.2.0 engine range" "26.13.1" "$(run 1.2.0)"

printf 'resolve-node: %d passed, %d failed\n' "$pass" "$failed"
(( failed == 0 ))
