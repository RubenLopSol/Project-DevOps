# =============================================================================
# Module: backup-storage
#
# Creates the S3 bucket for Velero backups and the Secrets Manager slot for
# the Sealed Secrets controller RSA key. These two resources are identical
# across all environments — only the names, tags, and retention period change.
# =============================================================================

# S3 bucket for Velero cluster backups
resource "aws_s3_bucket" "velero_backups" {
  bucket = var.bucket_name

  tags = merge(var.tags, {
    Purpose = "velero-backups"
  })
}

resource "aws_s3_bucket_versioning" "velero_backups" {
  bucket = aws_s3_bucket.velero_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero_backups" {
  bucket = aws_s3_bucket.velero_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero_backups" {
  bucket = aws_s3_bucket.velero_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "velero_backups" {
  count  = var.enable_lifecycle ? 1 : 0
  bucket = aws_s3_bucket.velero_backups.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = var.retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# =============================================================================
# Secrets Manager slot for the Sealed Secrets controller RSA key
#
# Terraform creates an empty slot. The actual key is written later:
#   make backup-sealing-key   → writes the key after controller starts
#   make restore-sealing-key  → reads the key back on cluster recovery
# =============================================================================
resource "aws_secretsmanager_secret" "sealed_secrets_key" {
  name                    = var.sealed_secrets_secret_name
  description             = "Sealed Secrets controller RSA key pair — backup for cluster recovery"
  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(var.tags, {
    Purpose = "sealed-secrets-key-backup"
  })
}
