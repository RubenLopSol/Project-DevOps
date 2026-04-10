output "iam_user_name" {
  description = "IAM user name"
  value       = aws_iam_user.velero.name
}

output "access_key_id" {
  description = "Access Key ID — write to credentials-velero as aws_access_key_id"
  value       = aws_iam_access_key.velero.id
}

output "secret_access_key" {
  description = "Secret Access Key — write to credentials-velero as aws_secret_access_key"
  value       = aws_iam_access_key.velero.secret
  sensitive   = true
}

output "velero_install_command" {
  description = "Ready-to-run velero install command using the static credentials file"
  value       = <<-EOT
    velero install \
      --provider aws \
      --plugins velero/velero-plugin-for-aws:v1.8.0 \
      --bucket <bucket-name> \
      --backup-location-config region=us-east-1,s3Url=http://localhost:4566,s3ForcePathStyle=true \
      --use-volume-snapshots=false \
      --namespace velero \
      --secret-file ./credentials-velero
  EOT
}
