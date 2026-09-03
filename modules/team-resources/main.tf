locals {
  buckets_by_name = { for b in var.buckets : b.name => b }

  full_bucket_name = { for name, b in local.buckets_by_name : name => "${var.company_prefix}-${var.team_name}-${name}" }

  private_bucket_names = [for name, b in local.buckets_by_name : name if b.visibility == "private"]
  public_bucket_names  = [for name, b in local.buckets_by_name : name if b.visibility == "public"]
}

# --- S3 buckets -------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  for_each = local.buckets_by_name

  bucket = local.full_bucket_name[each.key]

  tags = {
    Visibility = each.value.visibility
  }

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

data "aws_iam_policy_document" "deny_insecure_transport" {
  for_each = local.buckets_by_name

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this[each.key].arn, "${aws_s3_bucket.this[each.key].arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "public_read" {
  for_each = toset(local.public_bucket_names)

  statement {
    sid       = "PublicReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this[each.key].arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

# Private buckets only get the TLS-deny statement.
resource "aws_s3_bucket_policy" "private" {
  for_each = toset(local.private_bucket_names)

  bucket = aws_s3_bucket.this[each.key].id
  policy = data.aws_iam_policy_document.deny_insecure_transport[each.key].json
}

# Public buckets get TLS-deny plus the explicit public-read grant, combined
# into a single policy document (a bucket can only have one policy).
data "aws_iam_policy_document" "public_combined" {
  for_each = toset(local.public_bucket_names)

  source_policy_documents = [
    data.aws_iam_policy_document.deny_insecure_transport[each.key].json,
    data.aws_iam_policy_document.public_read[each.key].json,
  ]
}

resource "aws_s3_bucket_policy" "public" {
  for_each = toset(local.public_bucket_names)

  bucket     = aws_s3_bucket.this[each.key].id
  policy     = data.aws_iam_policy_document.public_combined[each.key].json
  depends_on = [aws_s3_bucket_public_access_block.public]
}

# --- IAM role ----------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.trusted_principal_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.team_name]
    }
  }
}

resource "aws_iam_role" "team" {
  name               = "${var.company_prefix}-${var.team_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  description        = "Role for team ${var.team_name}, scoped to its own S3 buckets."
}

# Built from the buckets this module actually created for this team - never
# a wildcard/prefix - so a naming collision elsewhere can't grant access.
data "aws_iam_policy_document" "team_bucket_access" {
  statement {
    sid    = "ListOwnBuckets"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [for b in aws_s3_bucket.this : b.arn]
  }

  statement {
    sid    = "ReadWriteOwnObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [for b in aws_s3_bucket.this : "${b.arn}/*"]
  }
}

resource "aws_iam_role_policy" "team_bucket_access" {
  name   = "${var.team_name}-bucket-access"
  role   = aws_iam_role.team.id
  policy = data.aws_iam_policy_document.team_bucket_access.json
}
