#!/usr/bin/env bash
# Build a reproducible release tarball plus a standalone installer copy.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

version="$(bash deploy-dsh.sh version | awk '{ print $2 }')"
[[ -n "$version" ]] || { printf 'Cannot read version from deploy-dsh.sh\n' >&2; exit 1; }

name="dsh-deploy-${version}"
rm -rf dist
mkdir -p dist

tar --sort=name \
  --mtime='2026-11-23 00:00:00Z' \
  --owner=0 --group=0 --numeric-owner \
  -czf "dist/${name}.tar.gz" \
  deploy-dsh.sh README.md README.en.md LICENSE CHANGELOG.md SECURITY.md \
  CONTRIBUTING.md AGENTS.md Makefile .gitignore .github tests scripts

cp deploy-dsh.sh "dist/deploy-dsh-${version}.sh"
chmod 755 "dist/deploy-dsh-${version}.sh"

(
  cd dist
  sha256sum "${name}.tar.gz" "deploy-dsh-${version}.sh" > SHA256SUMS
)

printf 'Built dist/%s.tar.gz and dist/deploy-dsh-%s.sh\n' "$name" "$version"
cat dist/SHA256SUMS
