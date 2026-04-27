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

variable "role_name" {
  description = "Name for the Velero IAM Role. When null, falls back to the original 'velero-<eks_cluster_name>' pattern so existing callers keep their current name. Override per-environment when the role name has to match a pre-agreed value (e.g. one referenced from a Helm values file or runbook)."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to all IAM resources"
  type        = map(string)
  default     = {}
}
