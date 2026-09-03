variable "company_prefix" {
  description = "Short prefix applied to every bucket name, e.g. the company name. Set once by the platform, not by teams."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{1,10}$", var.company_prefix))
    error_message = "company_prefix must be 1-10 lowercase alphanumeric characters."
  }
}

variable "team_name" {
  description = "Team slug. Used in the IAM role name, bucket names, and the trust policy scope."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.team_name))
    error_message = "team_name must be lowercase alphanumeric/hyphen, 3-32 characters, and not start or end with a hyphen."
  }
}

variable "owner" {
  description = "Contact email for the team. Applied as the Owner tag."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.owner))
    error_message = "owner must be a valid email address."
  }
}

variable "cost_center" {
  description = "Finance cost center code. Applied as the CostCenter tag."
  type        = string

  validation {
    condition     = can(regex("^CC-[0-9]{3,6}$", var.cost_center))
    error_message = "cost_center must match CC-<3 to 6 digits>."
  }
}

variable "environment" {
  description = "Environment tag applied to every resource this module creates."
  type        = string
  default     = "prod"
}

variable "trusted_principal_arn" {
  description = "IAM principal ARN allowed to assume this team's role (e.g. the team's CI/CD role or SSO role)."
  type        = string
}

# Intentionally no default. A bucket entry missing `visibility`, or with any
# value other than "public"/"private", must fail terraform plan.
variable "buckets" {
  description = "S3 buckets to create for this team. Each entry must explicitly set visibility to \"public\" or \"private\" - there is no default."
  type = list(object({
    name       = string
    visibility = string
  }))

  validation {
    condition     = length(var.buckets) > 0
    error_message = "At least one bucket must be declared."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : contains(["public", "private"], b.visibility)
    ])
    error_message = "Each bucket's visibility must be exactly \"public\" or \"private\"."
  }

  validation {
    condition = alltrue([
      for b in var.buckets : can(regex("^[a-z0-9][a-z0-9-]{0,40}[a-z0-9]$", b.name))
    ])
    error_message = "Each bucket name must be lowercase alphanumeric/hyphen, 2-42 characters, and not start or end with a hyphen."
  }

  validation {
    condition     = length(distinct([for b in var.buckets : b.name])) == length(var.buckets)
    error_message = "Bucket names must be unique within a team."
  }
}
