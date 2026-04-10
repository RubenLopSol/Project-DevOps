output "bucket_name" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.velero_backups.id
}

output "bucket_arn" {
  description = "S3 bucket ARN"
  value       = aws_s3_bucket.velero_backups.arn
}

output "sealed_secrets_key_secret_arn" {
  description = "Secrets Manager ARN for the Sealed Secrets RSA key backup"
  value       = aws_secretsmanager_secret.sealed_secrets_key.arn
}
