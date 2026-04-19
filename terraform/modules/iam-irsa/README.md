# Module: `iam-irsa`

Creates an **IAM Role for Velero using IRSA** (IAM Roles for Service Accounts). Used in **real AWS (prod)** where the EKS cluster has an OIDC provider.

IRSA allows the Velero pod's Kubernetes ServiceAccount to assume an IAM Role **without static credentials**. The trust policy restricts assumption to exactly one ServiceAccount in one namespace on one specific cluster.

## Resources created

- `aws_iam_role.velero` — `velero-${eks_cluster_name}`; trust policy is `sts:AssumeRoleWithWebIdentity` federated through the EKS OIDC provider, restricted by `StringEquals` on the `sub` claim to `system:serviceaccount:${velero_namespace}:${velero_service_account}`.
- `aws_iam_policy.velero_s3` — `velero-s3-${eks_cluster_name}` (same S3 actions as `iam-user`).
- `aws_iam_role_policy_attachment.velero_s3`

### Data sources

- `aws_eks_cluster.this` — looks up the cluster by `var.eks_cluster_name`
- `aws_iam_openid_connect_provider.eks` — resolves the OIDC provider ARN from the cluster's `identity[0].oidc[0].issuer`

## Usage

```hcl
module "velero_iam" {
  source = "../../modules/iam-irsa"

  bucket_arn             = module.backup_storage.bucket_arn
  eks_cluster_name       = var.eks_cluster_name       # e.g. "openpanel-prod"
  velero_namespace       = "velero"
  velero_service_account = "velero"

  tags = {
    Project     = "openpanel"
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}
```

### Consuming the outputs

```bash
# Install Velero with IRSA — no credentials file needed
eval $(terraform output -raw velero_install_command)

# Or annotate the ServiceAccount manually
kubectl annotate sa -n velero velero \
  eks.amazonaws.com/role-arn=$(terraform output -raw role_arn)
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
| [aws_iam_policy.velero_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.velero](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.velero_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_eks_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_cluster) | data source |
| [aws_iam_openid_connect_provider.eks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_openid_connect_provider) | data source |
| [aws_iam_policy_document.velero_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.velero_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_bucket_arn"></a> [bucket\_arn](#input\_bucket\_arn) | ARN of the S3 bucket Velero is allowed to access | `string` | n/a | yes |
| <a name="input_eks_cluster_name"></a> [eks\_cluster\_name](#input\_eks\_cluster\_name) | EKS cluster name — used to look up the OIDC provider for IRSA | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to all IAM resources | `map(string)` | `{}` | no |
| <a name="input_velero_namespace"></a> [velero\_namespace](#input\_velero\_namespace) | Kubernetes namespace where Velero is installed | `string` | `"velero"` | no |
| <a name="input_velero_service_account"></a> [velero\_service\_account](#input\_velero\_service\_account) | Name of Velero's Kubernetes ServiceAccount | `string` | `"velero"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | IAM Role ARN — pass to velero install --sa-annotations iam.amazonaws.com/role=<ARN> |
| <a name="output_velero_install_command"></a> [velero\_install\_command](#output\_velero\_install\_command) | Ready-to-run velero install command with the IRSA role ARN filled in |
<!-- END_TF_DOCS -->
