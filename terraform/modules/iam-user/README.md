# Module: `iam-user`

Creates an **IAM User + access key** for Velero. Used in **LocalStack (staging)** where IRSA is not available because there is no real EKS OIDC provider.

> For real AWS environments prefer the [`iam-irsa`](../iam-irsa/README.md) module — no static credentials and stricter least-privilege.

## Resources created

- `aws_iam_user.velero` — `velero-backup-user`
- `aws_iam_policy.velero_s3` — `velero-s3-policy` (object: `Get/Put/Delete/AbortMultipartUpload/ListMultipartUploadParts` on `${bucket_arn}/*`; bucket: `ListBucket/GetBucketLocation` on `${bucket_arn}`)
- `aws_iam_user_policy_attachment.velero_s3`
- `aws_iam_access_key.velero` — returns `access_key_id` + `secret_access_key` (sensitive) for `credentials-velero`

## Usage

```hcl
module "velero_iam" {
  source = "../../modules/iam-user"

  bucket_arn  = module.backup_storage.bucket_arn
  bucket_name = var.bucket_name   # used in the velero_install_command output

  tags = {
    Project     = "openpanel"
    Environment = "staging"
    ManagedBy   = "terraform"
  }
}
```

### Consuming the outputs

```bash
# Write credentials file for velero install
terraform output -raw secret_access_key > /dev/null   # required to materialize the sensitive output
cat <<EOF > credentials-velero
[default]
aws_access_key_id     = $(terraform output -raw access_key_id)
aws_secret_access_key = $(terraform output -raw secret_access_key)
EOF

# Print the ready-to-run install command
terraform output -raw velero_install_command
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
| [aws_iam_access_key.velero](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_access_key) | resource |
| [aws_iam_policy.velero_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_user.velero](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user) | resource |
| [aws_iam_user_policy_attachment.velero_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_bucket_arn"></a> [bucket\_arn](#input\_bucket\_arn) | ARN of the S3 bucket Velero is allowed to access | `string` | n/a | yes |
| <a name="input_bucket_name"></a> [bucket\_name](#input\_bucket\_name) | Name of the S3 bucket Velero backs up to (used in the install command output) | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to all IAM resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_access_key_id"></a> [access\_key\_id](#output\_access\_key\_id) | Access Key ID — write to credentials-velero as aws\_access\_key\_id |
| <a name="output_iam_user_name"></a> [iam\_user\_name](#output\_iam\_user\_name) | IAM user name |
| <a name="output_secret_access_key"></a> [secret\_access\_key](#output\_secret\_access\_key) | Secret Access Key — write to credentials-velero as aws\_secret\_access\_key |
| <a name="output_velero_install_command"></a> [velero\_install\_command](#output\_velero\_install\_command) | Ready-to-run velero install command using the static credentials file |
<!-- END_TF_DOCS -->
