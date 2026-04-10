# =============================================================================
# Module: iam-user
#
# IAM User + Access Key for Velero.
# Used in LocalStack (local development) where IRSA is not available because
# there is no real EKS OIDC provider.
#
# In real AWS environments use the iam-irsa module instead — IRSA requires no
# static credentials and follows the principle of least privilege more strictly.
# =============================================================================

resource "aws_iam_policy" "velero_s3" {
  name        = "velero-s3-policy"
  description = "Minimal S3 permissions for Velero backup management"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VeleroS3ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${var.bucket_arn}/*"
      },
      {
        Sid    = "VeleroS3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = var.bucket_arn
      },
    ]
  })
}

resource "aws_iam_user" "velero" {
  name = "velero-backup-user"
  tags = var.tags
}

resource "aws_iam_user_policy_attachment" "velero_s3" {
  user       = aws_iam_user.velero.name
  policy_arn = aws_iam_policy.velero_s3.arn
}

resource "aws_iam_access_key" "velero" {
  user = aws_iam_user.velero.name
}
