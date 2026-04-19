variable "bucket_name" {
  description = "S3 bucket name for Velero backups (must be globally unique in AWS)"
  type        = string
  default     = "openpanel-velero-backups-prod"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "retention_days" {
  description = "Days before backup objects expire"
  type        = number
  default     = 90
}

variable "sealed_secrets_secret_name" {
  description = "Secrets Manager secret name for the Sealed Secrets RSA key"
  type        = string
  default     = "devops-cluster-prod/sealed-secrets-master-key"
}

variable "eks_cluster_name" {
  description = "EKS cluster name — used to look up the OIDC provider for IRSA"
  type        = string
  default     = "openpanel-prod"
}

variable "velero_namespace" {
  description = "Kubernetes namespace where Velero is installed"
  type        = string
  default     = "velero"
}

variable "velero_service_account" {
  description = "Name of Velero's Kubernetes ServiceAccount"
  type        = string
  default     = "velero"
}
