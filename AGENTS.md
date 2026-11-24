# AGENTS.md

## Checks

```bash
make check
```

## Rules

- Work on `agent/<task>`; never push `main` or force-push.
- Never read, print, or commit tokens, private keys, cookies, or `.env` files.
- Do not run `gh auth login`; use the operator-supplied repository credential.
- Keep `deploy-dsh.sh`, both READMEs, and `CHANGELOG.md` in sync.
- Add or update tests for behavior changes.

## Report

Branch, commit SHA, changed files, `make check` result, and risks.
