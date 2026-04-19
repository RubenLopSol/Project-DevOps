# Module: `backup-storage`

Provisions the **S3 bucket for Velero backups** and the **Secrets Manager slot for the Sealed Secrets RSA key**. These two resources are identical across environments — only names, tags, retention, and lifecycle behaviour change.

## Resources created

- `aws_s3_bucket.velero_backups` — backup bucket
- `aws_s3_bucket_versioning.velero_backups` — versioning `Enabled`
- `aws_s3_bucket_server_side_encryption_configuration.velero_backups` — `AES256`
- `aws_s3_bucket_public_access_block.velero_backups` — all 4 flags `true`
- `aws_s3_bucket_lifecycle_configuration.velero_backups` — optional; expires objects after `retention_days`, noncurrent versions after 7 days. Disabled in LocalStack (community edition does not support the lifecycle waiter).
- `aws_secretsmanager_secret.sealed_secrets_key` — empty slot; the actual RSA key is written later via `make backup-sealing-key` / `make restore-sealing-key`.

## Usage

### Staging (LocalStack)

```hcl
module "backup_storage" {
  source = "../../modules/backup-storage"

  bucket_name                 = "openpanel-velero-backups"
  retention_days              = 30
  sealed_secrets_secret_name  = "devops-cluster/sealed-secrets-master-key"
  secret_recovery_window_days = 0     # LocalStack: immediate deletion
  enable_lifecycle            = false # LocalStack does not support the lifecycle waiter

  tags = {
    Project     = "openpanel"
    Environment = "staging"
    ManagedBy   = "terraform"
  }
}
```

### Prod (real AWS)

```hcl
module "backup_storage" {
  source = "../../modules/backup-storage"

  bucket_name                 = "openpanel-velero-backups-prod"
  retention_days              = 90
  sealed_secrets_secret_name  = "devops-cluster/sealed-secrets-master-key"
  secret_recovery_window_days = 30    # longer recovery window in prod

  tags = {
    Project     = "openpanel"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |

## Resources

| Name | Type |
|------|------|
| [aws_s3_bucket.velero_backups](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.velero_backups](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_public_access_block.velero_backups](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.velero_backups](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.velero_backups](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_secretsmanager_secret.sealed_secrets_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_bucket_name"></a> [bucket\_name](#input\_bucket\_name) | Name of the S3 bucket for Velero backups (must be globally unique) | `string` | n/a | yes |
| <a name="input_enable_lifecycle"></a> [enable\_lifecycle](#input\_enable\_lifecycle) | Whether to create the S3 lifecycle expiry rule. Disable for LocalStack (community edition does not support the lifecycle waiter). | `bool` | `true` | no |
| <a name="input_retention_days"></a> [retention\_days](#input\_retention\_days) | Days before backup objects expire automatically | `number` | `30` | no |
| <a name="input_sealed_secrets_secret_name"></a> [sealed\_secrets\_secret\_name](#input\_sealed\_secrets\_secret\_name) | Name of the Secrets Manager secret for the Sealed Secrets RSA key | `string` | `"devops-cluster/sealed-secrets-master-key"` | no |
| <a name="input_secret_recovery_window_days"></a> [secret\_recovery\_window\_days](#input\_secret\_recovery\_window\_days) | Days before a deleted Secrets Manager secret is permanently removed (0 = immediate) | `number` | `7` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | S3 bucket ARN |
| <a name="output_bucket_name"></a> [bucket\_name](#output\_bucket\_name) | S3 bucket name |
| <a name="output_sealed_secrets_key_secret_arn"></a> [sealed\_secrets\_key\_secret\_arn](#output\_sealed\_secrets\_key\_secret\_arn) | Secrets Manager ARN for the Sealed Secrets RSA key backup |
<!-- END_TF_DOCS -->
