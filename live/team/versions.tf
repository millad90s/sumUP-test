terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Bucket, key, region, and dynamodb_table are supplied at `terraform init`
  # time via -backend-config, so this file never changes per team.
  backend "s3" {}
}
