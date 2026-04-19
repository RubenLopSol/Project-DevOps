module "backup_storage" {
  source = "../../modules/backup-storage"

  bucket_name                 = var.bucket_name
  retention_days              = var.retention_days
  sealed_secrets_secret_name  = var.sealed_secrets_secret_name
  secret_recovery_window_days = 30 # Longer recovery window for production secrets

  tags = {
    Project     = "openpanel"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

module "velero_iam" {
  source = "../../modules/iam-irsa"

  bucket_arn             = module.backup_storage.bucket_arn
  eks_cluster_name       = var.eks_cluster_name
  velero_namespace       = var.velero_namespace
  velero_service_account = var.velero_service_account

  tags = {
    Project     = "openpanel"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}
