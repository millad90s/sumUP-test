locals {
  buckets_by_name = { for b in var.buckets : b.name => b }

  full_bucket_name = { for name, b in local.buckets_by_name : name => "${var.company_prefix}-${var.team_name}-${name}" }

  private_bucket_names = [for name, b in local.buckets_by_name : name if b.visibility == "private"]
  public_bucket_names  = [for name, b in local.buckets_by_name : name if b.visibility == "public"]

  common_tags = {
    Owner       = var.owner
    CostCenter  = var.cost_center
    Environment = var.environment
  }
}

# --- S3 buckets -------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  for_each = local.buckets_by_name

  bucket = local.full_bucket_name[each.key]

  tags = merge(local.common_tags, {
    Visibility = each.value.visibility
  })

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", local.full_bucket_name[each.key]))
      error_message = "Composed bucket name '${local.full_bucket_name[each.key]}' is not a valid S3 bucket name (lowercase/hyphen, 3-63 chars)."
    }
    precondition {
      condition     = length(local.full_bucket_name[each.key]) <= 63
      error_message = "Composed bucket name '${local.full_bucket_name[each.key]}' exceeds the 63 character S3 bucket name limit."
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets_by_name

  bucket = aws_s3_bucket.this[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.buckets_by_name

  bucket = aws_s3_bucket.this[each.key].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Private buckets: fully locked down, no opt-out.
resource "aws_s3_bucket_public_access_block" "private" {
  for_each = toset(local.private_bucket_names)

  bucket                  = aws_s3_bucket.this[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Public buckets: relax only the two settings that block a public-read
# bucket policy from taking effect. ACLs stay blocked - access is granted
# solely through the explicit bucket policy below.
resource "aws_s3_bucket_public_access_block" "public" {
  for_each = toset(local.public_bucket_names)

  bucket                  = aws_s3_bucket.this[each.key].id
  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

locals {
  # Policies are built with jsonencode() over local values, rather than the
  # aws_iam_policy_document data source, so their content is fully computable
  # from configuration alone (needed for `terraform test` with mock_provider
  # to assert on real policy JSON instead of provider-mocked data).

  deny_insecure_transport_statement = {
    for name, b in local.buckets_by_name : name => {
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.this[name].arn, "${aws_s3_bucket.this[name].arn}/*"]
      Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
    }
  }

  public_read_statement = {
    for name in local.public_bucket_names : name => {
      Sid       = "PublicReadOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.this[name].arn}/*"
    }
  }

  private_bucket_policy = {
    for name in local.private_bucket_names : name => jsonencode({
      Version   = "2012-10-17"
      Statement = [local.deny_insecure_transport_statement[name]]
    })
  }

  public_bucket_policy = {
    for name in local.public_bucket_names : name => jsonencode({
      Version = "2012-10-17"
      Statement = [
        local.deny_insecure_transport_statement[name],
        local.public_read_statement[name],
      ]
    })
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.trusted_principal_arn }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "sts:ExternalId" = var.team_name
        }
      }
    }]
  })

  # Built from the buckets this module actually created for this team - never
  # a wildcard/prefix - so a naming collision elsewhere can't grant access.
  team_bucket_access_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListOwnBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [for b in aws_s3_bucket.this : b.arn]
      },
      {
        Sid      = "ReadWriteOwnObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [for b in aws_s3_bucket.this : "${b.arn}/*"]
      },
    ]
  })
}

# Private buckets only get the TLS-deny statement.
resource "aws_s3_bucket_policy" "private" {
  for_each = toset(local.private_bucket_names)

  bucket = aws_s3_bucket.this[each.key].id
  policy = local.private_bucket_policy[each.key]
}

# Public buckets get TLS-deny plus the explicit public-read grant, combined
# into a single policy document (a bucket can only have one policy).
resource "aws_s3_bucket_policy" "public" {
  for_each = toset(local.public_bucket_names)

  bucket     = aws_s3_bucket.this[each.key].id
  policy     = local.public_bucket_policy[each.key]
  depends_on = [aws_s3_bucket_public_access_block.public]
}

# --- IAM role ----------------------------------------------------------------

resource "aws_iam_role" "team" {
  name               = "${var.company_prefix}-${var.team_name}-role"
  assume_role_policy = local.assume_role_policy
  description        = "Role for team ${var.team_name}, scoped to its own S3 buckets."
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "team_bucket_access" {
  name   = "${var.team_name}-bucket-access"
  role   = aws_iam_role.team.id
  policy = local.team_bucket_access_policy
}
