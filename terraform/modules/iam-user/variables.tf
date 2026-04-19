variable "bucket_arn" {
  description = "ARN of the S3 bucket Velero is allowed to access"
  type        = string
}

variable "bucket_name" {
  description = "Name of the S3 bucket Velero backs up to (used in the install command output)"
  type        = string
}

variable "tags" {
  description = "Tags applied to all IAM resources"
  type        = map(string)
  default     = {}
}
