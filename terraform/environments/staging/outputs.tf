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

output "velero_iam_user" {
  description = "IAM user name created for Velero"
  value       = module.velero_iam.iam_user_name
}

output "velero_access_key_id" {
  description = "Access Key ID — write to credentials-velero"
  value       = module.velero_iam.access_key_id
}

output "velero_secret_access_key" {
  description = "Secret Access Key — write to credentials-velero"
  value       = module.velero_iam.secret_access_key
  sensitive   = true
}

output "velero_install_command" {
  description = "velero install command for staging (LocalStack)"
  value       = module.velero_iam.velero_install_command
}