variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_name" {
  description = "Name of the shared S3 bucket holding every team's Terraform state."
  type        = string
  default     = "acme-platform-terraform-state"
}

variable "lock_table_name" {
  description = "Name of the shared DynamoDB table used for state locking."
  type        = string
  default     = "acme-platform-terraform-locks"
}
