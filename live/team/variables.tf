variable "team_config_path" {
  description = "Path to the team's team.yaml file, e.g. ../../teams/acme-payments/team.yaml. Passed with -var at plan/apply time."
  type        = string
}

variable "company_prefix" {
  description = "Platform-wide prefix applied to every bucket name."
  type        = string
  default     = "acme"
}

variable "aws_region" {
  description = "AWS region resources are created in."
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID, used to build the ARN of the principal each team's role trusts."
  type        = string
}
