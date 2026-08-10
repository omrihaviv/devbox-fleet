terraform {
  required_version = ">= 1.9.0"

  # Local state: this root is two IAM resources applied a handful of times;
  # the GCS-backend investment stays with gcp/.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}
