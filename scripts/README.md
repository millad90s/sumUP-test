# scripts

- **`new-team.sh <team> <owner-email> <cost-center>`** — scaffolds `teams/<team>/team.yaml` from a
  template. This is the entire onboarding UX.
- **`detect-changed-teams.sh <base-ref> [head-ref]`** — diffs `teams/**/team.yaml` between two
  refs, prints (and, in CI, writes to `$GITHUB_OUTPUT`) `changed_teams`/`removed_teams` as JSON
  arrays for a workflow matrix. Used by both `.github/workflows/*.yml` and standalone.
- **`plan-team.sh <team>`** / **`apply-team.sh <team> [-auto-approve]`** — local dev wrappers
  around `terraform init`/`plan`/`apply` for one team, with the correct `-backend-config` and
  `-var` flags. Config via env vars: `STATE_BUCKET`, `LOCK_TABLE`, `AWS_REGION`,
  `COMPANY_PREFIX`, `AWS_ACCOUNT_ID` (required), and `ENDPOINT_URL` (set to
  `http://localhost:4566` to run against LocalStack instead of real AWS).

Example - onboard and plan a team locally against LocalStack:

```bash
./scripts/new-team.sh acme-fraud-detection acme-fraud-detection@company.com CC-2001
python3 tests/validate_team_configs.py

AWS_ACCOUNT_ID=000000000000 ENDPOINT_URL=http://localhost:4566 \
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
  ./scripts/plan-team.sh acme-fraud-detection
```
