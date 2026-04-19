# Terraform — Infrastructure as Code

Manages the external cloud infrastructure that the Kubernetes cluster depends on.
Two environments are supported: **staging** (LocalStack — runs locally in Docker) and **prod** (real AWS).

---

## Directory Structure

```
terraform/
├── environments/
│   ├── staging/          # LocalStack — simulates AWS locally
│   │   ├── backend.tf    # no remote backend — state stored locally
│   │   ├── versions.tf   # required Terraform and provider versions
│   │   ├── providers.tf  # AWS provider pointing to localhost:4566
│   │   ├── variables.tf  # staging-specific values
│   │   ├── main.tf       # calls backup-storage + iam-user modules
│   │   └── outputs.tf    # bucket name, IAM credentials, install commands
│   └── prod/             # Real AWS
│       ├── backend.tf    # remote state: S3 bucket + DynamoDB locking
│       ├── versions.tf   # required Terraform and provider versions
│       ├── providers.tf  # AWS provider (credentials from environment)
│       ├── variables.tf  # prod-specific values
│       ├── main.tf       # calls backup-storage + iam-irsa modules
│       └── outputs.tf    # bucket name, IAM role ARN, install commands
└── modules/
    ├── backup-storage/   # S3 bucket (versioned + encrypted) + Secrets Manager slot
    ├── iam-user/         # IAM User + Access Key — used in staging (no OIDC available)
    └── iam-irsa/         # IAM Role with OIDC trust policy — used in prod (EKS IRSA)
```

---

## What gets created

### Staging (LocalStack)

| Resource | Name |
|---|---|
| S3 bucket | `openpanel-velero-backups` |
| S3 versioning | Enabled |
| S3 encryption | AES256 |
| S3 public access block | All public access blocked |
| Secrets Manager secret | `devops-cluster/sealed-secrets-master-key` |
| IAM policy | `velero-s3-policy` |
| IAM user | `velero-backup-user` |
| IAM policy attachment | user ↔ policy |

### Prod (AWS)

Same S3 + Secrets Manager resources, but IAM user is replaced by an **IAM Role with OIDC trust policy** (IRSA) — no static credentials are stored anywhere.

---

## Role in the project lifecycle

Terraform provisions the **external state** that the Kubernetes cluster depends on but cannot manage itself. Everything inside the cluster (apps, controllers, dashboards, alert rules) is GitOps-managed by ArgoCD. Everything *outside* the cluster that the cluster reaches out to — the backup bucket, the IAM identity Velero uses to write to it, and the off-cluster slot where the Sealed Secrets key is backed up — is Terraform-managed.

### Per-resource purpose

| Resource | Consumer | Purpose |
|---|---|---|
| `aws_s3_bucket.velero_backups` | **Velero** (cluster backup controller) | Destination for scheduled cluster backups (manifests + PV snapshots). |
| `aws_s3_bucket_versioning` | Velero | Versioning protects backups from accidental overwrite/delete — required for point-in-time recovery. |
| `aws_s3_bucket_server_side_encryption_configuration` | AWS / Velero | AES256 at rest — security baseline. |
| `aws_s3_bucket_public_access_block` | AWS | Hard-blocks public exposure of the backup bucket. |
| `aws_s3_bucket_lifecycle_configuration` | AWS | Expires old backups after `retention_days` (30 staging / 90 prod). Skipped on LocalStack. |
| `aws_secretsmanager_secret.sealed_secrets_key` | **Sealed Secrets controller** (via `make backup-sealing-key` / `restore-sealing-key`) | Off-cluster slot holding the controller's RSA private key. Without this slot, a lost cluster means all `SealedSecret` manifests become un-decryptable forever. |
| **Staging** `aws_iam_user.velero` + `aws_iam_access_key` | Velero pod (via mounted `credentials-velero` file) | LocalStack has no OIDC provider, so Velero authenticates with a static access key. |
| **Prod** `aws_iam_role.velero` (IRSA) | Velero pod (via ServiceAccount annotation) | EKS OIDC provider mints short-lived STS tokens — no static credentials anywhere in the cluster or Git. |

### CI/CD lifecycle integration

**Stage ①** — Run `make terraform-infra ENV=<staging|prod>` once when bootstrapping a fresh environment. Outputs (`bucket_name`, IAM access key *or* role ARN, Secrets Manager ARN, `velero_install_command`) are consumed in stage ②.

**Stage ②** — Cluster-side install, still manual, still idempotent:
- `make backup-sealing-key` reads the Sealed Secrets controller's generated RSA key from the cluster and writes it into the Secrets Manager slot created in ①. On a new cluster, `make restore-sealing-key` pulls it back before any `SealedSecret` is applied — so all secret CRs in Git remain decryptable.
- `terraform output -raw velero_install_command` prints the exact `velero install` invocation pre-filled with the bucket name + credentials/role from ①.

**Stage ③** — Runtime. ArgoCD reconciles the cluster against Git and deploys the Velero + Sealed Secrets controllers. At that point:
- Velero writes nightly backups to the S3 bucket using the IAM identity from ①.
- Sealed Secrets controller decrypts `SealedSecret` CRs using the RSA key that stage ② seeded into the cluster.
- The S3 bucket also holds the cluster's disaster-recovery state — `velero restore` rebuilds the cluster from it.

**Stage ④** — CI. `terraform validate` and `terraform fmt -check` are planned for Gate 1 of the GitHub Actions pipeline (tracked in Phase 5); they are not wired up yet. Terraform **never runs `apply` in CI** in this project — applying cloud infra from a shared CI runner would require storing long-lived AWS credentials in GitHub and would make it easy to drift state by accident. Apply stays manual, auditable, and gated by human review of the plan.

### What Terraform deliberately does *not* manage

- **Anything inside the cluster** — Deployments, Services, ConfigMaps, CRDs, controllers. ArgoCD owns those.
- **App container images** — Built and pushed by the `ci-build-publish` workflow, tagged into manifests by `cd-update-tags`.
- **Cluster creation itself** — Minikube in staging, EKS in prod (EKS provisioning is out of thesis scope — flagged as task `2.9`).

---

## Local Setup — Staging

### Prerequisites

- Terraform >= 1.5.0
- Docker (for LocalStack)
- AWS CLI v2

### 1. Start LocalStack

LocalStack simulates AWS services locally inside a Docker container.

```bash
docker run -d --name localstack -p 4566:4566 localstack/localstack:3
```

Verify it is healthy:

```bash
curl http://localhost:4566/_localstack/health | jq
```

### 2. Provision infrastructure

```bash
# Using Make (recommended)
make terraform-infra ENV=staging

# Or manually
cd terraform/environments/staging
terraform init
terraform plan
terraform apply
```

### 3. Check Terraform outputs

```bash
cd terraform/environments/staging

terraform output
```

Get the Velero access key:

```bash
terraform output velero_access_key_id
terraform output -raw velero_secret_access_key
```

---

## Verify Created Resources

All commands below query LocalStack directly using the AWS CLI.
No real AWS credentials are needed — LocalStack accepts any value.

### S3 — List all buckets

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    s3 ls
```

Expected output:
```
openpanel-velero-backups
```

### S3 — Check versioning is enabled

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    s3api get-bucket-versioning \
    --bucket openpanel-velero-backups
```

Expected output:
```json
{
    "Status": "Enabled"
}
```

### S3 — Check encryption is configured

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    s3api get-bucket-encryption \
    --bucket openpanel-velero-backups
```

### S3 — Check public access is blocked

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    s3api get-public-access-block \
    --bucket openpanel-velero-backups
```

### IAM — List users

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    iam list-users \
    --query 'Users[].{User:UserName,ARN:Arn}' \
    --output table
```

Expected output:
```
velero-backup-user
```

### IAM — Check policies attached to Velero user

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    iam list-attached-user-policies \
    --user-name velero-backup-user \
    --query 'AttachedPolicies[].{Policy:PolicyName,ARN:PolicyArn}' \
    --output table
```

### IAM — List access keys for Velero user

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    iam list-access-keys \
    --user-name velero-backup-user \
    --query 'AccessKeyMetadata[].{KeyId:AccessKeyId,Status:Status}' \
    --output table
```

### Secrets Manager — List secrets

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    secretsmanager list-secrets \
    --query 'SecretList[].{Name:Name,ARN:ARN}' \
    --output table
```

Expected output:
```
devops-cluster/sealed-secrets-master-key
```

### Terraform — List all managed resources

```bash
cd terraform/environments/staging && terraform state list
```

Expected output:
```
module.backup_storage.aws_s3_bucket.velero_backups
module.backup_storage.aws_s3_bucket_versioning.velero_backups
module.backup_storage.aws_s3_bucket_server_side_encryption_configuration.velero_backups
module.backup_storage.aws_s3_bucket_public_access_block.velero_backups
module.backup_storage.aws_secretsmanager_secret.sealed_secrets_key
module.velero_iam.aws_iam_policy.velero_s3
module.velero_iam.aws_iam_user.velero
module.velero_iam.aws_iam_user_policy_attachment.velero_s3
module.velero_iam.aws_iam_access_key.velero
```

---

## Teardown

```bash
# Using Make (recommended)
make terraform-destroy ENV=staging

# Or manually
cd terraform/environments/staging && terraform destroy

# Stop and remove LocalStack
docker stop localstack && docker rm localstack
```

---

## Notes

- **Staging uses LocalStack** — all resources are created in a local Docker container. Nothing touches real AWS.
- **Prod uses IRSA** — no static IAM credentials are created. The Kubernetes ServiceAccount receives a temporary token via OIDC.
- The `credentials-velero` file written after staging apply is git-ignored — it contains the IAM access key in plaintext and must never be committed.
