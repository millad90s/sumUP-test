# Multi-Tenant AWS Provisioning System

Self-service Terraform platform: each product team declares a YAML file, and gets one IAM role +
N S3 buckets provisioned via CI/CD, with isolated Terraform state, at a scale of 1 to 300+ teams
with **zero platform code changes per team**.

> Placeholder note: bucket/company naming uses the prefix `acme` throughout this repo. Swap it for
> a real value via the `company_prefix` variable in `live/team/` — nothing else needs to change.

---

## Status

This README will be filled in with full design rationale, onboarding/offboarding walkthroughs,
and a "what I'd do differently at scale" section in Phase 5. This section currently documents the
**architecture contract** so we can agree on it before any Terraform is written.

## Architecture

```
                         ┌─────────────────────────────────────────────┐
                         │              teams/<team>/team.yaml          │
                         │  (the ONLY file a team owns or edits)        │
                         └───────────────────────┬───────────────────────┘
                                                  │ validated against
                                                  ▼
                         ┌─────────────────────────────────────────────┐
                         │     teams/schema/team.schema.json            │
                         │  (JSON Schema contract, checked in CI first) │
                         └───────────────────────┬───────────────────────┘
                                                  │ yamldecode(file(...))
                                                  ▼
┌───────────────────────────┐   calls    ┌─────────────────────────────────┐
│   live/team/ (ROOT)        │───────────▶│  modules/team-resources/         │
│   ONE generic config,      │            │  - 1 IAM role (trust scoped      │
│   identical for every team │            │    to the team)                  │
│   backend "s3" {} (empty,  │            │  - N S3 buckets from bucket list │
│   filled at init time)     │            │  - naming + policy enforcement    │
└───────────────┬────────────┘            └─────────────────────────────────┘
                 │ terraform init -backend-config=...
                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Shared platform state backend (bootstrapped ONCE, bootstrap/)           │
│  - 1 S3 bucket for all team state                                        │
│  - 1 DynamoDB lock table                                                 │
│  - key per team: teams/<team>/terraform.tfstate  (full isolation,        │
│    no per-team bucket sprawl)                                            │
└─────────────────────────────────────────────────────────────────────────┘

CI/CD (.github/workflows/):
  push/PR touching teams/**/team.yaml
     └─▶ detect-changed-teams (git diff)  ──▶  JSON matrix
              └─▶ per changed team (parallel): init → validate → plan → PR comment
     └─▶ on merge to main: apply per changed team, gated by protected Environment
     └─▶ removed team.yaml: plan -destroy only, gated by manual approval (never auto-destroy)
```

### Key design decisions (rationale expanded in Phase 5)

1. **One generic root module (`live/team/`), not one root per team.** Adding team #301 means
   adding a YAML file, not writing/copying Terraform. This is the mechanism that gives us "zero
   platform code changes per team."
2. **`visibility` has no default anywhere.** A missing or misspelled value must fail `terraform
   plan`/schema validation, not silently default to private or public. Explicit opt-in only for
   public buckets.
3. **Naming enforced in the module via `validation` blocks**, not left to caller discipline —
   invalid names fail at `plan`, never reach `apply`.
4. **IAM policy built from actual created bucket ARNs** (module resource/output references), never
   a wildcard or prefix match — a naming collision cannot leak access across teams.
5. **Shared state bucket + DynamoDB table, per-team state *key*.** Full isolation (no team can see
   or lock another's state) without operating 300 S3 buckets. Tradeoff vs. Terraform
   Cloud/Enterprise workspaces documented in Phase 5.
6. **CI diff-based matrix.** Only changed teams plan/apply, in parallel, so the pipeline's runtime
   doesn't grow linearly with total team count — only with the number of teams changing in a given
   push.
7. **Offboarding is a human-gated `plan -destroy`, never automatic.** Deleting a `team.yaml` file
   must never silently delete real infrastructure.

## Repository layout

```
modules/team-resources/   Reusable Terraform module (IAM role + S3 buckets for one team)
live/team/                Generic root config, identical for every team
teams/<team>/team.yaml    Per-team self-service declaration (only file a team owns)
teams/schema/             JSON Schema contract for team.yaml
teams/_offboarded/        Archived team.yaml files after offboarding
bootstrap/                One-time platform state backend bootstrap (run manually)
.github/workflows/        CI/CD: plan on PR, apply on merge, destroy-on-removal flow
scripts/                  Onboarding/local-dev helper scripts
tests/                    terraform test suite + schema contract test
```

## Contract: `teams/<team>/team.yaml`

See [teams/schema/team.schema.json](teams/schema/team.schema.json) for the formal JSON Schema.
Example:

```yaml
team: acme-payments
owner: acme-payments@company.com
cost_center: CC-1234
buckets:
  - name: uploads
    visibility: private
  - name: public-assets
    visibility: public
```

Example teams included in this repo (`teams/`):

| Team | Demonstrates |
|---|---|
| `acme-payments` | single private bucket (baseline case) |
| `acme-analytics` | multiple buckets, all private |
| `acme-marketing-site` | a public bucket alongside a private one |
| `edge-max-len-team-01` | team+bucket name combination near the 63-char S3 limit |

## Roadmap (phased delivery)

- [x] **Phase 1** — repo skeleton, this README's architecture section, JSON Schema, example teams
- [x] **Phase 2** — `modules/team-resources` + `live/team`, fully working, module README
- [ ] **Phase 3** — full test suite (terraform test, schema contract test, tflint/checkov), run locally
- [ ] **Phase 4** — GitHub Actions workflows + `scripts/`
- [ ] **Phase 5** — README polish, decision rationale, onboarding/offboarding walkthroughs, at-scale section
