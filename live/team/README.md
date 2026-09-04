# live/team

Root Terraform config for a single team. Not applied directly by hand - it's invoked once per
team, with a different backend and `team.yaml` each time, via `scripts/plan-team.sh` /
`scripts/apply-team.sh` locally, or the `team-plan.yml` / `team-apply.yml` GitHub Actions
workflows in CI. See [modules/team-resources](../../modules/team-resources/README.md) for what
actually gets created.

## Why this exists separately from the module

`modules/team-resources` only defines resources - it has no provider, no backend, and cannot be
applied on its own. `live/team` is the thing that:

- Configures the `aws` provider (region, endpoint override for LocalStack, `default_tags`).
- Declares the `s3` backend (bucket/key/table supplied at `terraform init` time, so this file
  never changes per team - see `versions.tf`).
- Reads one team's `teams/<team>/team.yaml` and passes its values into the module.

The same `live/team` directory is reused for every team - only the backend key and
`team_config_path` change between runs. There is no `live/team/acme-payments`,
`live/team/acme-analytics`, etc.; one root config, one state file per team.

## Inputs

| Name | Type | Description | Default |
|---|---|---|---|
| `team_config_path` | `string` | Path to the team's `team.yaml`, e.g. `../../teams/acme-payments/team.yaml`. Passed with `-var` at plan/apply time. | none |
| `company_prefix` | `string` | Platform-wide prefix applied to every bucket name. | `"acme"` |
| `aws_region` | `string` | AWS region resources are created in. | `"us-east-1"` |
| `aws_account_id` | `string` | AWS account ID, used to build the ARN of the principal the team's role trusts. | none |
| `endpoint_url` | `string` | Optional custom endpoint (e.g. `http://localhost:4566` for LocalStack) for s3/iam/sts/dynamodb. Empty means real AWS. | `""` |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | ARN of the team's IAM role. |
| `bucket_names` | Map of bucket key to full S3 bucket name. |
| `bucket_arns` | Map of bucket key to bucket ARN. |

## Tagging

`default_tags` is set here on the `provider` block from `local.team_config` (decoded from
`team.yaml`): `Team`, `Owner`, `CostCenter`, `Environment`, `ManagedBy`. These apply to every
resource the module creates. The module itself only adds the per-bucket `Visibility` tag, since
that's the one thing that varies within a single team's apply.

## Usage

Prefer the wrapper scripts over calling `terraform` directly - they set the correct
`-backend-config` and `-var` flags for you:

```bash
AWS_ACCOUNT_ID=123456789012 ./scripts/plan-team.sh acme-payments
AWS_ACCOUNT_ID=123456789012 ./scripts/apply-team.sh acme-payments
```

Equivalent manual invocation, for reference:

```bash
cd live/team

terraform init \
  -backend-config="bucket=acme-platform-terraform-state" \
  -backend-config="key=teams/acme-payments/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=acme-platform-terraform-locks"

terraform plan \
  -var="team_config_path=../../teams/acme-payments/team.yaml" \
  -var="aws_account_id=123456789012"
```

Against LocalStack instead of real AWS, add `-var="endpoint_url=http://localhost:4566"` (and use
dummy AWS credentials - see `scripts/README.md`).

## CI

- `team-plan.yml` runs `terraform plan` here for every team whose `team.yaml` changed in a PR
  (as detected by `scripts/detect-changed-teams.sh`).
- `team-apply.yml` runs `terraform apply` here for the same set of teams once a PR merges to
  `master`.

Each team gets its own isolated state (`teams/<team>/terraform.tfstate` in the shared backend
created by [bootstrap](../../bootstrap/README.md)), so one team's plan/apply never touches
another's.
