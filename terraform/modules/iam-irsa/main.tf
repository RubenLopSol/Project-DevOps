# =============================================================================
# Module: iam-irsa
#
# IAM Role for Velero using IRSA (IAM Roles for Service Accounts).
# Used in real AWS environments where an EKS cluster has an OIDC provider.
#
# IRSA allows the Velero pod's Kubernetes ServiceAccount to assume an IAM Role
# without static credentials. The trust policy restricts assumption to exactly
# one ServiceAccount in one namespace on one specific cluster.
# =============================================================================

data "aws_eks_cluster" "this" {
  name = var.eks_cluster_name
}

data "aws_iam_openid_connect_provider" "eks" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_iam_policy_document" "velero_s3" {
  statement {
    sid    = "VeleroS3ObjectAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = ["${var.bucket_arn}/*"]
  }

  statement {
    sid    = "VeleroS3BucketAccess"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = [var.bucket_arn]
  }
}

data "aws_iam_policy_document" "velero_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.velero_namespace}:${var.velero_service_account}"]
    }
  }
}

resource "aws_iam_role" "velero" {
  name               = coalesce(var.role_name, "velero-${var.eks_cluster_name}")
  assume_role_policy = data.aws_iam_policy_document.velero_assume_role.json

  tags = var.tags
}

resource "aws_iam_policy" "velero_s3" {
  name        = "velero-s3-${var.eks_cluster_name}"
  description = "Minimal S3 permissions for Velero backup management"
  policy      = data.aws_iam_policy_document.velero_s3.json
}

resource "aws_iam_role_policy_attachment" "velero_s3" {
  role       = aws_iam_role.velero.name
  policy_arn = aws_iam_policy.velero_s3.arn
}
