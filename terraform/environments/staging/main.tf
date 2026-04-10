module "backup_storage" {
  source = "../../modules/backup-storage"

  bucket_name                 = var.bucket_name
  retention_days              = var.retention_days
  sealed_secrets_secret_name  = var.sealed_secrets_secret_name
  secret_recovery_window_days = 0  # LocalStack: immediate deletion (no waiting period)
  enable_lifecycle            = false  # LocalStack community does not support S3 lifecycle waiters

  tags = {
    Project     = "openpanel"
    Environment = "staging"
    ManagedBy   = "terraform"
  }
}

module "velero_iam" {
  source = "../../modules/iam-user"

  bucket_arn = module.backup_storage.bucket_arn

  tags = {
    Project     = "openpanel"
    Environment = "staging"
    ManagedBy   = "terraform"
  }
}