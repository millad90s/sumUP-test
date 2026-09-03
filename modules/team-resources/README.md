# team-resources module

Creates one IAM role and one or more S3 buckets for a single product team. This is the only
place naming, tagging, and security defaults are defined - callers cannot override them.

## What it creates

- One `aws_iam_role`, trust-scoped to a given principal ARN plus an `sts:ExternalId` condition
  equal to the team name.
- One `aws_iam_role_policy` on that role, built from the ARNs of the buckets this module just
  created for this team (never a wildcard or prefix), granting `ListBucket` on the buckets and
  `GetObject`/`PutObject`/`DeleteObject` on their objects.
- One `aws_s3_bucket` per entry in `var.buckets`, named `<company_prefix>-<team_name>-<bucket.name>`.
- For every bucket, regardless of visibility: versioning enabled, default SSE (AES256), and a
  bucket policy denying any request made without TLS.
- For `private` buckets (the default posture, always applied, no opt-out): Block Public Access
  fully enabled.
- For `public` buckets (explicit opt-in only): only `block_public_policy` and
  `restrict_public_buckets` are relaxed - ACLs stay blocked - and an explicit
  `s3:GetObject`-only public-read policy is attached alongside the TLS-deny statement.

## Naming convention

Final bucket name: `<company_prefix>-<team_name>-<bucket.name>`, e.g. `acme-payments-uploads`.
Enforced two ways:

1. `company_prefix`, `team_name`, and each bucket `name` each have a `validation` block
   restricting them to lowercase alphanumeric/hyphen. An invalid value fails `terraform plan`.
2. A `lifecycle.precondition` on `aws_s3_bucket` re-checks the *composed* name (character set and
   the 63-character S3 limit) once all three pieces are combined, since a single variable's
   `validation` block cannot see the other variables. This also fails at plan time, not apply.

## Visibility has no default

`var.buckets` declares no default, and `visibility` is a required attribute of the object type -
Terraform rejects a bucket entry that omits it. A `validation` block further rejects any value
other than exactly `"public"` or `"private"`. A team cannot end up with a bucket whose visibility
was silently assumed.

## Inputs

| Name | Type | Description | Default |
|---|---|---|---|
| `company_prefix` | `string` | Prefix applied to every bucket name. Platform-owned. | none |
| `team_name` | `string` | Team slug. Used in role name, bucket names, trust condition. | none |
| `owner` | `string` | Team contact email. Applied as the `Owner` tag by the caller's provider config. | none |
| `cost_center` | `string` | Finance cost center code, format `CC-<digits>`. | none |
| `environment` | `string` | Environment tag. | `"prod"` |
| `trusted_principal_arn` | `string` | IAM principal allowed to assume the team's role. | none |
| `buckets` | `list(object({ name = string, visibility = string }))` | Buckets to create. `visibility` must be `"public"` or `"private"`. | none |

## Outputs

| Name | Description |
|---|---|
| `role_arn` | ARN of the team's IAM role. |
| `role_name` | Name of the team's IAM role. |
| `bucket_names` | Map of bucket key to full S3 bucket name. |
| `bucket_arns` | Map of bucket key to bucket ARN. |

## Tagging

This module does not set provider-level `default_tags` - that's the caller's job, since tags like
`Team`/`Owner`/`CostCenter`/`Environment` are the same for every resource in one team's apply and
belong on the `provider` block (see `live/team/main.tf`). This module adds one resource-level tag,
`Visibility`, on each bucket, since that varies per bucket rather than per team.

## Usage

```hcl
module "team" {
  source = "../../modules/team-resources"

  company_prefix         = "acme"
  team_name               = "acme-payments"
  owner                    = "acme-payments@company.com"
  cost_center              = "CC-1234"
  trusted_principal_arn    = "arn:aws:iam::123456789012:role/acme-payments-ci"

  buckets = [
    { name = "uploads",       visibility = "private" },
    { name = "public-assets", visibility = "public" },
  ]
}
```

In practice this module is not called directly by teams - `live/team/` calls it with values
decoded from a team's `team.yaml`.
