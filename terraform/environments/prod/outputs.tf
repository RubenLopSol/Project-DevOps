output "bucket_name" {
  description = "S3 bucket name"
  value       = module.backup_storage.bucket_name
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = module.backup_storage.bucket_arn
}

output "sealed_secrets_key_secret_arn" {
  description = "Secrets Manager ARN for the Sealed Secrets key backup"
  value       = module.backup_storage.sealed_secrets_key_secret_arn
}

output "velero_role_arn" {
  description = "IAM Role ARN for Velero IRSA"
  value       = module.velero_iam.role_arn
}

output "velero_install_command" {
  description = "velero install command with IRSA role ARN filled in"
  value       = module.velero_iam.velero_install_command
}
