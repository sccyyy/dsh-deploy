# Security policy

Report vulnerabilities privately through GitHub's **Report a vulnerability** advisory flow. Do not open a public issue.

Include the script version (`./deploy-dsh.sh version`), distribution, and reproduction steps.

Secrets:

- The journal URL contains a DSH token; treat it as secret.
- Model credentials live in the data directory with mode `0600`.
- Never paste tokens, App private keys, or session cookies into issues or PRs.
