# Apply with an admin/deployer principal that can manage IAM roles and
# policies named devbox-* (role/policy CRUD + AttachRolePolicy + Get*/List*
# reads). No OIDC provider resource is needed — Google is built into AWS
# web-identity federation.
provider "aws" {
  region              = "us-east-1" # IAM is global; region only routes the API calls
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project   = var.project_tag
      ManagedBy = "terraform"
    }
  }
}
