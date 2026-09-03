# bootstrap

Creates the shared state backend: one S3 bucket (versioned, encrypted, private) and one DynamoDB
lock table. Run once by the platform team, manually, before onboarding the first team.

```
cd bootstrap
terraform init
terraform apply
```

This config has its own local state (there's no state to isolate yet - it creates the thing that
isolates everyone else's state). Keep that local state file somewhere safe, or move it to a
backend of its own after the first apply.

Every team's `live/team` config then points at the bucket/table this creates, via
`-backend-config`, with a state key unique to that team:

```
terraform init \
  -backend-config="bucket=acme-platform-terraform-state" \
  -backend-config="key=teams/acme-payments/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=acme-platform-terraform-locks"
```
