variable "aws_account_id" {
  description = "AWS account this root is allowed to apply against (fail-closed via allowed_account_ids)."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "sa_unique_id" {
  description = "NUMERIC unique ID of the devbox-instance GCP service account — from `terraform -chdir=gcp output -raw devbox_instance_sa_unique_id`. Never the email: emails are reusable after SA deletion; the unique ID pins the exact SA. If the SA is ever recreated, this value changes and this root MUST be re-applied."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{10,30}$", var.sa_unique_id))
    error_message = "sa_unique_id must be the SA's numeric unique ID (digits only), not its email."
  }
}

variable "audience" {
  description = "Dedicated audience string for identity tokens. MUST equal the GCP root's var.aws_federation_audience — tokens minted for AWS must not be replayable elsewhere."
  type        = string
  default     = "devbox-fleet-aws-federation"
  validation {
    condition     = trimspace(var.audience) != ""
    error_message = "audience must be non-empty."
  }
}

variable "project_tag" {
  description = "Value of the Project default tag on the two IAM resources this root manages."
  type        = string
  default     = "devbox-fleet"
}
