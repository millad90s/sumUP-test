# Multi-Tenant AWS Provisioning System

Self-service Terraform platform: each product team declares a YAML file, and gets one IAM role +
N S3 buckets provisioned via CI/CD, with isolated Terraform state, at a scale of 1 to 300+ teams
with **zero platform code changes per team**.

> Placeholder note: bucket/company naming uses the prefix `acme` throughout this repo. Swap it for
> a real value via the `company_prefix` variable in `live/team/` — nothing else needs to change.

---

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

---

## Onboarding a new team (self-service, ~3 steps)

A team never touches Terraform. The whole flow:

```bash
# 1. Scaffold the declaration
./scripts/new-team.sh acme-fraud-detection acme-fraud-detection@company.com CC-2001

# 2. Edit teams/acme-fraud-detection/team.yaml - add/rename buckets, set each
#    bucket's visibility explicitly. Validate locally before opening a PR:
python3 tests/validate_team_configs.py

# 3. Open a PR
git checkout -b onboard-acme-fraud-detection
git add teams/acme-fraud-detection/team.yaml
git commit -m "onboard acme-fraud-detection"
git push -u origin onboard-acme-fraud-detection
```

`team-plan.yml` picks up the new `teams/acme-fraud-detection/team.yaml`, validates it against the
schema, and posts a `terraform plan` on the PR showing exactly the role and buckets that will be
created. A platform engineer reviews and merges; `team-apply.yml` then applies it behind the
`production` protected environment. The team never needs platform engineering to touch code, and
the platform module never needs to change to accommodate them — that's the whole design.

## Offboarding sequence

Deleting `teams/<team>/team.yaml` never auto-destroys anything. The flow:

1. Open a PR removing `teams/<team>/team.yaml`. `team-plan.yml` detects it as a removal and posts
   a `plan -destroy` on the PR for review — this is the last chance to catch a mistake before
   anything is scheduled for deletion.
2. Merge the PR. `team-apply.yml` runs `offboard-destroy`, which pauses for approval in the
   `production-destroy` protected environment (a separate gate from routine applies).
3. A platform team member approves. The job destroys the team's IAM role and S3 buckets.
4. After a successful destroy, manually remove the team's state key
   (`teams/<team>/terraform.tfstate`) from the shared state bucket, and move the historical
   `team.yaml` into `teams/_offboarded/<team>/team.yaml` in a follow-up commit (kept for audit
   trail, no longer read by any workflow since it's outside `teams/*/team.yaml`'s active glob).

## CI/CD: how the pipeline knows what changed

Both workflows are keyed off `scripts/detect-changed-teams.sh` — a `git diff --name-status`
between two refs, filtered to `teams/*/team.yaml`, split into added/modified ("changed", needs
plan/apply) vs. deleted ("removed", needs an offboard plan-destroy). It's a plain shell script,
runnable standalone (`./scripts/detect-changed-teams.sh origin/main HEAD`) or from CI, and its
output feeds a GitHub Actions matrix (`fromJson(...)`) so each affected team plans/applies in its
own parallel job. A push touching 3 of 300 teams only touches those 3 — the pipeline's runtime
scales with the size of a change, not the size of the fleet.

- **`team-plan.yml`** (PR touching `teams/**/team.yaml`): schema validation → `fmt`/`tflint`/
  `checkov` → the module's `terraform test` suite → per changed team: `init → validate → plan`,
  posted as a PR comment. Per removed team: `plan -destroy`, posted as a warning comment.
  Nothing is ever applied or destroyed from a PR - this workflow only ever plans, which is what
  makes it safe to run on untrusted PR branches.
- **`team-apply.yml`** (push to `main`, i.e. right after a plan PR is merged): applies changed
  teams under the `production` GitHub Environment (requires a reviewer approval before the job
  runs), destroys removed teams under a *separate* `production-destroy` Environment. Splitting
  these into two environments means approving a routine bucket addition can never accidentally
  also approve someone else's offboarding destroy sitting in the same batch of changes.

## Tagging and cost allocation

Every resource gets `Team`, `Owner`, `CostCenter`, `Environment`, and `ManagedBy=terraform` via
the AWS provider's `default_tags` (set once, in `live/team/main.tf`, from the values decoded out
of that team's `team.yaml` — never hand-typed per resource). Each bucket additionally gets a
`Visibility` tag (`public`/`private`) at the resource level, since that varies per bucket rather
than per team. This gives finance a clean `CostCenter` dimension to slice AWS Cost Explorer by
with no extra tooling, and gives the platform team `Team`/`Owner` for "who do I page" without
having to cross-reference a spreadsheet.

## Testing

See [tests/README.md](tests/README.md) for the full breakdown and exact commands. In short:
`terraform test` against `modules/team-resources` with `mock_provider "aws" {}` (8 tests, no AWS
account needed - naming, private/public bucket posture, IAM policy scoping, and 4 validation-
failure cases), a Python contract test validating every `teams/*/team.yaml` against the JSON
Schema, and `checkov`/`tflint` as static guardrails. All of it was run locally and passed before
each phase was called done - see the commit history rather than taking that on faith.

---

## Key design decisions

**One generic root config (`live/team/`), not one root per team.**
Adding team #301 means adding a YAML file, not writing or copying Terraform. This is the actual
mechanism behind "zero platform code changes per team" - there's no template to stamp out, no
per-team directory of `.tf` files to keep in sync. The tradeoff is that `live/team/` can only ever
express what the module's inputs allow; a team that needs something the module doesn't support
(a DynamoDB table, say) needs the module extended, not a one-off root config bypassing it. That's
intentional - it's the guardrail, not a limitation to route around.

**`visibility` has no default anywhere.**
The `buckets` variable has no default value, and `visibility` inside each bucket object is typed
`optional(string)` (so a missing key doesn't hard-fail on type conversion before validation even
runs) but a `validation` block then explicitly rejects `null` and anything other than
`"public"`/`"private"`. The distinction matters: if I'd typed it as a plain required `string`,
Terraform's own type-checking would reject a missing key with a generic type error rather than our
validation block's message - functionally similar, but it means the "no default" rule is enforced
by the module's own logic, not by an accident of the type system. A team cannot end up with a
bucket whose visibility was silently assumed.

**Naming enforced in the module via `validation` blocks, not left to caller discipline.**
Each of `company_prefix`, `team_name`, and every bucket `name` has its own regex `validation`
(lowercase/hyphen only, bounded length). Since a `validation` block can only see its own
variable, the *composed* name (`<prefix>-<team>-<bucket>`) is re-checked with a
`lifecycle.precondition` on `aws_s3_bucket` once all three pieces are known - catching the case
where each part is individually valid but the combination exceeds S3's 63-character limit.
Both fail at `terraform plan`, never at `apply`, so a bad name is caught before any CI approval
gate is even reached.

**IAM policy built from the actual bucket resources this module created, never a wildcard.**
`aws_iam_role_policy.team_bucket_access`'s `Resource` list is `[for b in aws_s3_bucket.this : b.arn]`
- generated from the real `aws_s3_bucket` resources this specific module invocation created,
not a `arn:aws:s3:::${company_prefix}-${team_name}-*` pattern. A pattern-based policy would be
simpler to write, but it means a naming collision or a manually-created bucket that happens to
match the pattern silently grants that team access. Building the resource list from the actual
created resources makes that class of bug structurally impossible rather than something to
remember to avoid.

**Public bucket policies use `jsonencode()` over local values, not the `aws_iam_policy_document`
data source.**
Functionally equivalent output, but `aws_iam_policy_document` is a data source - under
`mock_provider` (used by `terraform test`), all data sources of a mocked provider return
fake/mocked values, not their real computed content. That would make it impossible to assert on
real policy JSON in tests. `jsonencode()` over a local value is pure Terraform-language
computation with no provider round-trip, so its output is real and assertable even fully mocked.
This is a good example of testability shaping an implementation choice without changing what gets
deployed.

**Shared state bucket + DynamoDB table, per-team state *key*, not one state bucket per team.**
`bootstrap/` creates exactly one S3 bucket and one DynamoDB table, once. Every team's `live/team`
apply uses that same bucket/table via `-backend-config`, differing only in
`key=teams/<team>/terraform.tfstate`. This gives full isolation - no team can see, lock, or
corrupt another team's state, since S3 keys and DynamoDB lock rows are independent - without the
platform team operating and monitoring 300 S3 buckets (IAM policies, encryption, versioning,
lifecycle rules, replicated 300 times) for what is fundamentally one concern: "store Terraform
state safely." The alternative most people reach for here is Terraform Cloud/Enterprise
workspaces (or Spacelift/env0/similar), which would give the same per-team isolation plus a UI,
run history, and policy-as-code (Sentinel/OPA) for free, at the cost of a paid product and a new
system to operate. For a take-home exercise assessed on raw Terraform/AWS fundamentals, the
S3+DynamoDB backend demonstrates the mechanism directly; at a real 300-team organization I'd
seriously evaluate TFC/TFE specifically for its policy-as-code and run-visibility story - see "at
scale" below.

**CI diff-based matrix, not "plan/apply everything on every push."**
`scripts/detect-changed-teams.sh` is a small, standalone, testable script (not inlined into YAML)
that both CI and a human run the same way. Its output becomes a GitHub Actions matrix, so N
changed teams run as N parallel jobs regardless of how many teams exist in total - the pipeline's
cost and runtime track the size of a change, not the size of the fleet, which is what makes "1 to
300+ teams... zero platform code changes" also true of the *pipeline*, not just the Terraform.

**Offboarding is a human-gated `plan -destroy`, never automatic.**
Deleting a `team.yaml` file is a two-key operation: the PR shows the destroy plan (so a reviewer
sees exactly what would be deleted before merge), and the actual destroy runs behind its own
`production-destroy` protected environment on merge - deliberately separate from the `production`
environment used for routine applies, so approving one can never accidentally approve the other.

---

## What I'd do differently running this in production at real scale

- **State backend.** S3+DynamoDB works and is transparent, but at 300+ teams I'd move to Terraform
  Cloud/Enterprise (or a managed equivalent) primarily for **policy-as-code** (Sentinel/OPA) as a
  hard gate ahead of apply - e.g. "no bucket policy may grant `s3:*`", "every role's trust policy
  must include the `ExternalId` condition" - enforced centrally instead of only living in this
  module's Terraform logic, which a determined engineer could still bypass by calling the AWS API
  directly. TFC/TFE also gives run history and drift visibility out of the box instead of me
  building it.
- **Drift detection.** Nothing here currently detects a bucket policy edited by hand outside
  Terraform. I'd add a scheduled (nightly) `terraform plan` per team - reusing the exact same
  `plan-team.sh` logic the CI plan job already uses - that fails loudly (paging the platform team,
  not the tenant team) on any non-empty diff, before it's discovered the hard way.
- **CI AWS auth.** The workflows here reference `secrets.AWS_ACCOUNT_ID` and have OIDC steps
  commented out, because I don't have a real AWS account or GitHub repo to wire up end-to-end.
  In production this is non-negotiable: GitHub Actions OIDC federation to a role scoped narrowly
  to `s3:*`/`iam:*` on this platform's own resource prefix, no long-lived `AWS_ACCESS_KEY_ID`
  secrets, separate roles for the plan job (broad read, no write) and the apply job (write, but
  still not `*`).
- **Module versioning.** `live/team/` currently pins the module via a relative path
  (`../../modules/team-resources`), so every team is always on whatever's on `main` - fine for a
  single-repo exercise, risky at scale, since a bad module change would potentially affect all 300
  teams' next apply simultaneously. I'd publish the module to a private registry with semantic
  versions, pin `live/team/` to a version range, and roll changes out gradually rather than
  atomically.
- **Blast-radius limits.** Right now nothing stops a single CI run from applying (or destroying)
  many teams at once if many `team.yaml` files change in one push - each matrix entry is
  independent but nothing caps how many run concurrently. I'd add a `max-parallel` cap on the
  matrix and, for destroys specifically, a hard ceiling ("no more than N teams destroyed per
  day without a break-glass override") to bound how much damage one mistake (or one compromised
  credential) can do in a single run.
- **Cross-account isolation.** All teams currently share one AWS account. At real scale I'd put
  each team (or each business unit) in its own AWS account under AWS Organizations, with this same
  module deploying into per-account roles via `assume_role` - blast radius from a compromised
  team's role would then stop at the account boundary instead of merely at the IAM policy boundary
  this module currently provides.
- **Secrets and config beyond S3/IAM.** This exercise only covers IAM role + S3 buckets. A real
  platform team's "one file, self-service" pattern would need to extend the same `team.yaml` +
  module shape to KMS keys, Secrets Manager, SQS/SNS, and RDS - the schema and CI mechanism here
  generalize directly, but each resource type needs its own guardrails (the way `visibility` is
  the guardrail for S3) worked out deliberately, not copy-pasted.

## Roadmap (phased delivery)

- [x] **Phase 1** — repo skeleton, this README's architecture section, JSON Schema, example teams
- [x] **Phase 2** — `modules/team-resources` + `live/team`, fully working, module README
- [x] **Phase 3** — full test suite (terraform test, schema contract test, tflint/checkov), run locally
- [x] **Phase 4** — GitHub Actions workflows + `scripts/`
- [x] **Phase 5** — README polish, decision rationale, onboarding/offboarding walkthroughs, at-scale section
