variable "bucket_arn" {
  description = "ARN of the S3 bucket Velero is allowed to access"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name — used to look up the OIDC provider for IRSA"
  type        = string
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

variable "tags" {
  description = "Tags applied to all IAM resources"
  type        = map(string)
  default     = {}
}
