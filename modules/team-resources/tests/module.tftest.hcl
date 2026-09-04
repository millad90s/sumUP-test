# Runs entirely against a mocked AWS provider - no real credentials or
# network access needed. `command = apply` lets the mock provider generate
# fake-but-known values for computed attributes (like bucket ARNs) so we can
# assert on them; `command = plan` is used for the validation-failure tests,
# since those fail before any resource would be created.

mock_provider "aws" {}

variables {
  company_prefix        = "acme"
  owner                 = "acme-payments@company.com"
  cost_center           = "CC-1234"
  trusted_principal_arn = "arn:aws:iam::123456789012:role/acme-payments-ci"
}

# --- naming convention -------------------------------------------------------

run "naming_convention" {
  command = apply

  variables {
    team_name = "acme-payments"
    buckets = [
      { name = "uploads", visibility = "private" },
    ]
  }

  assert {
    condition     = output.bucket_names["uploads"] == "acme-acme-payments-uploads"
    error_message = "Bucket name did not follow the <company_prefix>-<team>-<bucket> convention."
  }

  assert {
    condition     = aws_iam_role.team.name == "acme-acme-payments-role"
    error_message = "IAM role name did not follow the <company_prefix>-<team>-role convention."
  }
}

# --- private buckets: locked down, no opt-out --------------------------------

run "private_bucket_locked_down" {
  command = apply

  variables {
    team_name = "acme-analytics"
    buckets = [
      { name = "raw-events", visibility = "private" },
    ]
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.private["raw-events"].block_public_acls == true
    error_message = "Private bucket must block public ACLs."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.private["raw-events"].block_public_policy == true
    error_message = "Private bucket must block public bucket policies."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.private["raw-events"].restrict_public_buckets == true
    error_message = "Private bucket must restrict public buckets."
  }

  assert {
    condition     = aws_s3_bucket_versioning.this["raw-events"].versioning_configuration[0].status == "Enabled"
    error_message = "Private bucket must have versioning enabled."
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.this["raw-events"].rule :
      r.apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    ])
    error_message = "Private bucket must have default SSE enabled."
  }

  assert {
    condition     = !contains(keys(aws_s3_bucket_policy.public), "raw-events")
    error_message = "A private bucket must never get a public bucket policy resource."
  }

  assert {
    condition     = strcontains(aws_s3_bucket_policy.private["raw-events"].policy, "DenyInsecureTransport")
    error_message = "Private bucket policy must deny non-TLS requests."
  }

  assert {
    condition     = !strcontains(aws_s3_bucket_policy.private["raw-events"].policy, "PublicReadOnly")
    error_message = "Private bucket policy must not contain a public-read statement."
  }
}

# --- public buckets: explicit opt-in only -------------------------------------

run "public_bucket_relaxed_correctly" {
  command = apply

  variables {
    team_name = "acme-marketing-site"
    buckets = [
      { name = "assets", visibility = "public" },
    ]
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.public["assets"].block_public_acls == true
    error_message = "Public bucket must still block public ACLs - access is granted via bucket policy only."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.public["assets"].block_public_policy == false
    error_message = "Public bucket must relax block_public_policy so the public-read policy can take effect."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.public["assets"].restrict_public_buckets == false
    error_message = "Public bucket must relax restrict_public_buckets so the public-read policy can take effect."
  }

  assert {
    condition     = !contains(keys(aws_s3_bucket_policy.private), "assets")
    error_message = "A public bucket must never get the private-only bucket policy resource."
  }

  assert {
    condition     = strcontains(aws_s3_bucket_policy.public["assets"].policy, "PublicReadOnly")
    error_message = "Public bucket policy must contain the explicit public-read statement."
  }

  assert {
    condition     = strcontains(aws_s3_bucket_policy.public["assets"].policy, "DenyInsecureTransport")
    error_message = "Public bucket policy must still deny non-TLS requests."
  }
}

# --- IAM policy scoped to only this team's buckets ----------------------------

run "iam_policy_scoped_to_own_buckets_only" {
  command = apply

  variables {
    team_name = "acme-analytics"
    buckets = [
      { name = "raw-events", visibility = "private" },
      { name = "curated", visibility = "private" },
      { name = "exports", visibility = "private" },
    ]
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.team_bucket_access.policy, "\"Resource\":\"*\"")
    error_message = "IAM policy must never use a wildcard resource."
  }

  assert {
    condition = alltrue([
      for arn in values(output.bucket_arns) : strcontains(aws_iam_role_policy.team_bucket_access.policy, arn)
    ])
    error_message = "IAM policy must reference every bucket this module created for the team."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.team_bucket_access.policy).Statement) == 2
    error_message = "IAM policy should have exactly two statements: list buckets and read/write objects."
  }
}

# --- validation: visibility has no default ------------------------------------

run "missing_visibility_fails_validation" {
  command = plan

  variables {
    team_name = "acme-payments"
    buckets = [
      { name = "uploads" },
    ]
  }

  expect_failures = [var.buckets]
}

run "invalid_visibility_value_fails_validation" {
  command = plan

  variables {
    team_name = "acme-payments"
    buckets = [
      { name = "uploads", visibility = "read-only" },
    ]
  }

  expect_failures = [var.buckets]
}

run "invalid_team_name_fails_validation" {
  command = plan

  variables {
    team_name = "Acme_Payments!"
    buckets = [
      { name = "uploads", visibility = "private" },
    ]
  }

  expect_failures = [var.team_name]
}

run "duplicate_bucket_names_fail_validation" {
  command = plan

  variables {
    team_name = "acme-payments"
    buckets = [
      { name = "uploads", visibility = "private" },
      { name = "uploads", visibility = "public" },
    ]
  }

  expect_failures = [var.buckets]
}

run "uppercase_bucket_name_fails_validation" {
  command = plan

  variables {
    team_name = "acme-payments"
    buckets = [
      { name = "Uploads", visibility = "private" },
    ]
  }

  expect_failures = [var.buckets]
}

run "single_char_bucket_name_fails_validation" {
  command = plan

  variables {
    team_name = "acme-payments"
    buckets = [
      { name = "a", visibility = "private" },
    ]
  }

  expect_failures = [var.buckets]
}

run "invalid_owner_email_fails_validation" {
  command = plan

  variables {
    team_name = "acme-payments"
    owner     = "not-an-email"
    buckets = [
      { name = "uploads", visibility = "private" },
    ]
  }

  expect_failures = [var.owner]
}

run "invalid_cost_center_fails_validation" {
  command = plan

  variables {
    team_name   = "acme-payments"
    cost_center = "CC-1"
    buckets = [
      { name = "uploads", visibility = "private" },
    ]
  }

  expect_failures = [var.cost_center]
}

run "uppercase_company_prefix_fails_validation" {
  command = plan

  variables {
    team_name      = "acme-payments"
    company_prefix = "ACME"
    buckets = [
      { name = "uploads", visibility = "private" },
    ]
  }

  expect_failures = [var.company_prefix]
}

run "empty_buckets_list_fails_validation" {
  command = plan

  variables {
    team_name = "acme-payments"
    buckets   = []
  }

  expect_failures = [var.buckets]
}

# --- boundary: composed bucket name over the 63-char S3 limit -----------------

run "composed_bucket_name_over_length_limit_fails" {
  command = plan

  variables {
    team_name      = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" # 32 chars: max valid team_name length
    company_prefix = "aaaaaaaaaa"                       # 10 chars: max valid company_prefix length
    buckets = [
      { name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", visibility = "private" }, # 42 chars: max valid bucket name length
    ]
  }

  expect_failures = [aws_s3_bucket.this]
}

# --- mixed visibility within the same team -------------------------------------

run "mixed_public_and_private_buckets_isolated_correctly" {
  command = apply

  variables {
    team_name = "acme-analytics"
    buckets = [
      { name = "raw-events", visibility = "private" },
      { name = "public-dashboard", visibility = "public" },
    ]
  }

  assert {
    condition     = contains(keys(aws_s3_bucket_policy.private), "raw-events")
    error_message = "The private bucket must get the private-only policy."
  }

  assert {
    condition     = !contains(keys(aws_s3_bucket_policy.private), "public-dashboard")
    error_message = "The public bucket must not get the private-only policy."
  }

  assert {
    condition     = contains(keys(aws_s3_bucket_policy.public), "public-dashboard")
    error_message = "The public bucket must get the public-read policy."
  }

  assert {
    condition     = !contains(keys(aws_s3_bucket_policy.public), "raw-events")
    error_message = "The private bucket must not get the public-read policy."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.team_bucket_access.policy).Statement[0].Resource) == 2
    error_message = "The team's IAM policy must still list both buckets regardless of their visibility."
  }
}

# --- assume-role trust is scoped with an ExternalId ----------------------------

run "assume_role_requires_matching_external_id" {
  command = apply

  variables {
    team_name = "acme-payments"
    buckets = [
      { name = "uploads", visibility = "private" },
    ]
  }

  assert {
    condition = jsondecode(aws_iam_role.team.assume_role_policy).Statement[0].Condition.StringEquals["sts:ExternalId"] == "acme-payments"
    error_message = "The assume-role trust policy must require an ExternalId matching the team name, to prevent confused-deputy assumption."
  }
}
