variable "bucket_arn" {
  description = "ARN of the S3 bucket Velero is allowed to access"
  type        = string
}

variable "tags" {
  description = "Tags applied to all IAM resources"
  type        = map(string)
  default     = {}
}
