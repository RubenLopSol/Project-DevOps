variable "bucket_name" {
  description = "Name of the S3 bucket for Velero backups (must be globally unique)"
  type        = string
}

variable "retention_days" {
  description = "Days before backup objects expire automatically"
  type        = number
  default     = 30
}

variable "sealed_secrets_secret_name" {
  description = "Name of the Secrets Manager secret for the Sealed Secrets RSA key"
  type        = string
  default     = "devops-cluster/sealed-secrets-master-key"
}

variable "secret_recovery_window_days" {
  description = "Days before a deleted Secrets Manager secret is permanently removed (0 = immediate)"
  type        = number
  default     = 7
}

variable "enable_lifecycle" {
  description = "Whether to create the S3 lifecycle expiry rule. Disable for LocalStack (community edition does not support the lifecycle waiter)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
