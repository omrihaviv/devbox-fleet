output "role_arn" {
  description = "Paste into gcp/terraform.tfvars as bedrock_role_arn, then re-apply gcp/."
  value       = aws_iam_role.devbox_gcp_workload.arn
}
