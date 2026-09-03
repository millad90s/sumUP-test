locals {
  team_config = yamldecode(file(var.team_config_path))
}

provider "aws" {
  region = var.aws_region

  # s3_use_path_style is required for LocalStack (and any S3-compatible
  # endpoint that doesn't support virtual-hosted-style addressing); it is a
  # no-op against real AWS. Endpoint overrides are opt-in via TF_VAR_endpoint_url.
  s3_use_path_style = var.endpoint_url != "" ? true : false

  # LocalStack Community doesn't implement the S3 Control API the provider
  # uses to reconcile default_tags drift, and account-id lookup via STS is
  # unnecessary here since aws_account_id is already passed in explicitly.
  skip_requesting_account_id = var.endpoint_url != ""

  dynamic "endpoints" {
    for_each = var.endpoint_url != "" ? [1] : []
    content {
      s3        = var.endpoint_url
      s3control = var.endpoint_url
      iam       = var.endpoint_url
      sts       = var.endpoint_url
      dynamodb  = var.endpoint_url
    }
  }

  default_tags {
    tags = {
      Team        = local.team_config.team
      Owner       = local.team_config.owner
      CostCenter  = local.team_config.cost_center
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

# Platform convention: each team has a CI role of this name, created outside
# this config. See README for the onboarding sequence.
module "team" {
  source = "../../modules/team-resources"

  company_prefix        = var.company_prefix
  team_name             = local.team_config.team
  owner                 = local.team_config.owner
  cost_center           = local.team_config.cost_center
  trusted_principal_arn = "arn:aws:iam::${var.aws_account_id}:role/${local.team_config.team}-ci"
  buckets               = local.team_config.buckets
}
