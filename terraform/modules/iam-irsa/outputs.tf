output "role_arn" {
  description = "IAM Role ARN — pass to velero install --sa-annotations iam.amazonaws.com/role=<ARN>"
  value       = aws_iam_role.velero.arn
}

output "velero_install_command" {
  description = "Ready-to-run velero install command with the IRSA role ARN filled in"
  value       = <<-EOT
    velero install \
      --provider aws \
      --plugins velero/velero-plugin-for-aws:v1.8.0 \
      --bucket ${var.bucket_arn} \
      --backup-location-config region=$(aws configure get region) \
      --use-volume-snapshots=false \
      --namespace velero \
      --sa-annotations iam.amazonaws.com/role=${aws_iam_role.velero.arn}
  EOT
}
