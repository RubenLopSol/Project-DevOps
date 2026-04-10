variable "bucket_name" {
  description = "S3 bucket name for Velero backups"
  type        = string
  default     = "openpanel-velero-backups"
}

variable "aws_region" {
  description = "Region (LocalStack accepts any value)"
  type        = string
  default     = "us-east-1"
}

variable "retention_days" {
  description = "Days before backup objects expire"
  type        = number
  default     = 30
}

variable "sealed_secrets_secret_name" {
  description = "Secrets Manager secret name for the Sealed Secrets RSA key"
  type        = string
  default     = "devops-cluster/sealed-secrets-master-key"
}