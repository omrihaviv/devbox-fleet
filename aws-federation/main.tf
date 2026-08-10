# Shared AWS workload identity for the GCP devbox fleet.
# ONE role + ONE policy — deliberately NO aws_iam_openid_connect_provider:
# Google is built into AWS web-identity federation and AWS documentation
# says not to create a separate provider for it.
#
# Trust-condition claim mapping for Google SA identity tokens:
#   accounts.google.com:sub  ← token `sub`  = SA numeric unique ID
#   accounts.google.com:aud  ← token `azp`  = SA numeric unique ID
#   accounts.google.com:oaud ← token `aud`  = our dedicated audience string
#
# ATTRIBUTION IS BEST-EFFORT: RoleSessionName (set to the hostname by
# devbox-aws-creds) is caller-supplied; the only SIGNED identity is the
# shared SA. sourceIPAddress corroborates. Genuine per-machine identity =
# per-machine SAs behind this same role (re-apply on fleet changes).

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["accounts.google.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:sub"
      values   = [var.sa_unique_id]
    }
    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:aud"
      values   = [var.sa_unique_id]
    }
    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:oaud"
      values   = [var.audience]
    }
  }
}

resource "aws_iam_role" "devbox_gcp_workload" {
  name               = "devbox-gcp-workload"
  description        = "Shared identity for GCP devboxes (Bedrock for Claude Code). Assumed keylessly via GCP identity tokens."
  assume_role_policy = data.aws_iam_policy_document.trust.json
  # 12h (AWS cap): bclaude injects credentials at launch and a session keeps
  # them for its lifetime — 12h covers a full dev day without mid-session expiry.
  max_session_duration = 43200
}

# Initial grant: Bedrock model invocation + discovery. Extend service by
# service as needs appear — never widen to bedrock:* wholesale.
data "aws_iam_policy_document" "bedrock_invoke" {
  statement {
    sid    = "InvokeClaudeModels"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${var.aws_account_id}:inference-profile/*",
    ]
  }

  statement {
    sid    = "DiscoverModels"
    effect = "Allow"
    actions = [
      "bedrock:ListFoundationModels",
      "bedrock:ListInferenceProfiles",
      "bedrock:GetFoundationModel",
      "bedrock:GetInferenceProfile",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "devbox_gcp_workload" {
  name   = "devbox-gcp-workload"
  policy = data.aws_iam_policy_document.bedrock_invoke.json
}

resource "aws_iam_role_policy_attachment" "devbox_gcp_workload" {
  role       = aws_iam_role.devbox_gcp_workload.name
  policy_arn = aws_iam_policy.devbox_gcp_workload.arn
}
