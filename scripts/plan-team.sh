#!/usr/bin/env bash
# Local dev wrapper: init + plan live/team for a single team, with the
# correct -backend-config and -var flags. Mirrors what the CI plan job does.
#
# Usage: plan-team.sh <team-name>
#
# Config comes from env vars, all with sane defaults matching bootstrap/'s
# defaults, except AWS_ACCOUNT_ID which is required:
#   STATE_BUCKET, LOCK_TABLE, AWS_REGION, COMPANY_PREFIX, AWS_ACCOUNT_ID
#   ENDPOINT_URL  - set to http://localhost:4566 to plan against LocalStack

set -euo pipefail

TEAM="${1:?Usage: plan-team.sh <team-name>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_YAML="$REPO_ROOT/teams/$TEAM/team.yaml"

if [ ! -f "$TEAM_YAML" ]; then
  echo "No such team config: teams/$TEAM/team.yaml" >&2
  exit 1
fi

STATE_BUCKET="${STATE_BUCKET:-acme-platform-terraform-state}"
LOCK_TABLE="${LOCK_TABLE:-acme-platform-terraform-locks}"
AWS_REGION="${AWS_REGION:-us-east-1}"
COMPANY_PREFIX="${COMPANY_PREFIX:-acme}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
ENDPOINT_URL="${ENDPOINT_URL:-}"

cd "$REPO_ROOT/live/team"

backend_flags=(
  -backend-config="bucket=$STATE_BUCKET"
  -backend-config="key=teams/$TEAM/terraform.tfstate"
  -backend-config="region=$AWS_REGION"
  -backend-config="dynamodb_table=$LOCK_TABLE"
)
if [ -n "$ENDPOINT_URL" ]; then
  backend_flags+=(
    -backend-config="skip_credentials_validation=true"
    -backend-config="skip_metadata_api_check=true"
    -backend-config="skip_requesting_account_id=true"
    -backend-config="use_path_style=true"
    -backend-config="endpoints={\"s3\":\"$ENDPOINT_URL\",\"iam\":\"$ENDPOINT_URL\",\"sts\":\"$ENDPOINT_URL\",\"dynamodb\":\"$ENDPOINT_URL\"}"
  )
fi

terraform init -input=false -reconfigure "${backend_flags[@]}"

terraform plan \
  -var="team_config_path=$TEAM_YAML" \
  -var="aws_account_id=$AWS_ACCOUNT_ID" \
  -var="aws_region=$AWS_REGION" \
  -var="company_prefix=$COMPANY_PREFIX" \
  -var="endpoint_url=$ENDPOINT_URL"
