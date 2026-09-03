#!/usr/bin/env bash
# Local dev wrapper: init + apply live/team for a single team. Same config
# as plan-team.sh. Prompts for confirmation unless -auto-approve is passed.
#
# Usage: apply-team.sh <team-name> [-auto-approve]

set -euo pipefail

TEAM="${1:?Usage: apply-team.sh <team-name> [-auto-approve]}"
AUTO_APPROVE_FLAG="${2:-}"

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

extra_flags=()
if [ -n "$AUTO_APPROVE_FLAG" ]; then
  extra_flags+=("$AUTO_APPROVE_FLAG")
fi

terraform apply "${extra_flags[@]}" \
  -var="team_config_path=$TEAM_YAML" \
  -var="aws_account_id=$AWS_ACCOUNT_ID" \
  -var="aws_region=$AWS_REGION" \
  -var="company_prefix=$COMPANY_PREFIX" \
  -var="endpoint_url=$ENDPOINT_URL"
