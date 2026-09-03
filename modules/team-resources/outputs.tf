output "role_arn" {
  description = "ARN of the team's IAM role."
  value       = aws_iam_role.team.arn
}

output "role_name" {
  description = "Name of the team's IAM role."
  value       = aws_iam_role.team.name
}

output "bucket_names" {
  description = "Map of bucket key (as declared in team.yaml) to the full S3 bucket name."
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "bucket_arns" {
  description = "Map of bucket key (as declared in team.yaml) to the bucket ARN."
  value       = { for k, b in aws_s3_bucket.this : k => b.arn }
}
