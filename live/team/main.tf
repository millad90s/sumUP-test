locals {
  team_config = yamldecode(file(var.team_config_path))
}

provider "aws" {
  region = var.aws_region

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
