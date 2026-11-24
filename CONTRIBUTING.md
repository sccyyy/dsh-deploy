# Contributing

```bash
make check      # bash -n + shellcheck + tests
```

- Branch: `agent/<task>` or `<type>/<task>`; never push `main`.
- Keep commits focused; add tests for behavior changes.
- Update `CHANGELOG.md` and both READMEs for user-visible changes.
- Open a pull request; CI must pass.

Release: bump `SCRIPT_VERSION`, update `CHANGELOG.md`, run `make package`, tag `vX.Y.Z`.

Security issues: see [SECURITY.md](SECURITY.md).
