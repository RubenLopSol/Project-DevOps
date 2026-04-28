# Terraform — Infrastructure as Code

This directory holds the cloud-side state the cluster needs but can't manage on its own: the S3 bucket Velero writes backups to, the IAM identity Velero uses, and an empty Secrets Manager slot reserved for the Sealed Secrets RSA key (more on that below — it's not wired up yet).

There are two environments. **staging** runs against LocalStack so nothing touches real AWS. **prod** is the real-AWS layout used by the production-oriented design.

---

## Directory layout

```
terraform/
├── environments/
│   ├── staging/          # LocalStack — Docker container at localhost:4566
│   │   ├── versions.tf   # required Terraform + provider versions
│   │   ├── providers.tf  # AWS provider pointing at localhost:4566
│   │   ├── variables.tf  # staging defaults
│   │   ├── main.tf       # backup-storage + iam-user
│   │   └── outputs.tf    # bucket info, IAM creds, install command
│   │   # No backend.tf — state lives next to the config as terraform.tfstate
│   └── prod/             # Real AWS
│       ├── backend.tf    # S3 state bucket + DynamoDB lock table
│       ├── versions.tf
│       ├── providers.tf  # AWS provider, credentials from environment
│       ├── variables.tf
│       ├── main.tf       # backup-storage + iam-irsa
│       └── outputs.tf
└── modules/
    ├── backup-storage/   # S3 bucket (versioned, encrypted) + Secrets Manager slot
    ├── iam-user/         # IAM user + access key (used in staging — no OIDC on LocalStack)
    └── iam-irsa/         # IAM role with OIDC trust (used in prod — EKS IRSA)
```

---

## What gets created

### Staging (LocalStack)

| Resource | Name |
|---|---|
| S3 bucket | `openpanel-velero-backups` |
| S3 versioning | enabled |
| S3 encryption | AES256 |
| S3 public access block | all public access blocked |
| S3 lifecycle rule | **not created** (LocalStack community doesn't support the lifecycle waiter — `enable_lifecycle = false`) |
| Secrets Manager secret | `devops-cluster/sealed-secrets-master-key` (empty slot) |
| IAM policy | `velero-s3-policy` |
| IAM user | `velero-backup-user` |
| IAM access key | one key for the user above |

### Prod (AWS)

Same backup-storage shape, but with prod-scoped names and IRSA in place of the static IAM user:

| Resource | Name |
|---|---|
| S3 bucket | `openpanel-velero-backups-prod` |
| S3 lifecycle rule | created — expires objects after 90 days, prunes noncurrent versions after 7 |
| Secrets Manager secret | `devops-cluster-prod/sealed-secrets-master-key` (empty slot) |
| IAM role | `velero-prod-role` (name pinned because the IRSA annotation in `k8s/infrastructure/overlays/prod/velero-operator/values.yaml` expects exactly that) |
| IAM policy | `velero-s3-openpanel-prod` |

The IAM role's trust policy only allows assumption by `system:serviceaccount:velero:velero` on the `openpanel-prod` EKS cluster, via that cluster's OIDC provider. No static credentials end up in the cluster or in Git.

---

### Per-resource purpose

| Resource | Used by | Why |
|---|---|---|
| `aws_s3_bucket.velero_backups` | Velero | Destination for scheduled cluster backups (manifests + PV snapshots). |
| `aws_s3_bucket_versioning` | Velero | Versioning protects backups from accidental overwrite or delete. Required for point-in-time restore. |
| `aws_s3_bucket_server_side_encryption_configuration` | AWS / Velero | AES256 at rest. Baseline. |
| `aws_s3_bucket_public_access_block` | AWS | Hard block on public exposure of the backup bucket. |
| `aws_s3_bucket_lifecycle_configuration` | AWS | Expires backup objects after `retention_days` (30 staging, 90 prod). Skipped on LocalStack. |
| `aws_secretsmanager_secret.sealed_secrets_key` | *Reserved — see below* | Empty slot, provisioned now so a future ESO/AWS migration has a place to land. Not consumed by anything in the repo today. |
| Staging `aws_iam_user.velero` + `aws_iam_access_key.velero` | Velero pod | LocalStack has no OIDC provider, so Velero authenticates with a static access key written into `credentials-velero`. |
| Prod `aws_iam_role.velero` (IRSA) | Velero pod | EKS OIDC mints short-lived STS tokens for the ServiceAccount. No static creds anywhere. |

### Sealing-key backup — what actually happens

The README used to claim `make backup-sealing-key` and `make restore-sealing-key` round-trip the Sealed Secrets RSA key through the Secrets Manager slot above. That isn't true today. The real flow is:

- `scripts/ensure-sealing-key.sh` creates or restores the keypair as a Kubernetes Secret in the `sealed-secrets` namespace, labelled so the controller adopts it on first start.
- The off-cluster backup is a local file at `~/.config/openpanel/sealing-key.yaml`, written and read by that same script.
- `scripts/stabilize-secrets.sh` waits for the controller, then waits for every `SealedSecret` in Git to materialise into a real `Secret`.

The Secrets Manager slot is provisioned anyway because moving the off-cluster backup from a local file to AWS Secrets Manager is the planned next step (and the same slot would serve an External Secrets Operator setup). Until that wiring lands, the slot stays empty.

### Lifecycle of a typical run

1. **Bootstrap** — `make terraform-infra ENV=<staging|prod>` once per environment. Outputs (`bucket_name`, IAM access key or role ARN, Secrets Manager ARN, `velero_install_command`) feed into step 2.
2. **Cluster bring-up** — `scripts/ensure-sealing-key.sh` plants the sealing key, then ArgoCD installs Velero + the Sealed Secrets controller. `terraform output -raw velero_install_command` prints the Velero install line with bucket and credentials already filled in.
3. **Runtime** — Velero writes nightly backups to S3 using the IAM identity from step 1. The Sealed Secrets controller decrypts `SealedSecret` CRs in Git using the key from step 2.
4. **CI** — Terraform is **not** run from CI. No `validate`, no `fmt -check`, no `apply`. Dependabot does watch provider versions in each `terraform/` directory (see `.github/dependabot.yml`). Apply stays manual on purpose: pushing AWS credentials into a shared CI runner to run `apply` makes drift and accidents too easy.

---

## Local setup (staging)

### Prerequisites

- Terraform >= 1.5.0
- Docker (for LocalStack)
- AWS CLI v2

### 1. Start LocalStack

```bash
docker run -d --name localstack -p 4566:4566 localstack/localstack:3
```

Health check:

```bash
curl http://localhost:4566/_localstack/health | jq
```

### 2. Provision

```bash
make terraform-infra ENV=staging
```

Or step-by-step:

```bash
cd terraform/environments/staging
terraform init
terraform plan
terraform apply
```

### 3. Inspect outputs

```bash
cd terraform/environments/staging
terraform output
```

The full set is `bucket_name`, `bucket_arn`, `sealed_secrets_key_secret_arn`, `velero_iam_user`, `velero_access_key_id`, `velero_secret_access_key` (sensitive), and `velero_install_command`. To pull the IAM credentials out for `credentials-velero`:

```bash
terraform output velero_access_key_id
terraform output -raw velero_secret_access_key
```

The prod equivalents are `bucket_name`, `bucket_arn`, `sealed_secrets_key_secret_arn`, `velero_role_arn`, `velero_install_command`. No access key — it's IRSA.

---

## Verifying the LocalStack resources

LocalStack accepts any credentials, so the CLI calls below use `--no-sign-request`. Output snippets are abridged — the real CLI adds a creation timestamp on bucket listings and table headers on `iam list-users` etc.

### S3 — list buckets

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    s3 ls
```

Expected output: `openpanel-velero-backups`.

### S3 — versioning

```bash
aws --endpoint-url http://localhost:4566 \
    --region us-east-1 \
    --no-sign-request \
    s3api get-bucket-versioning \
    --bucket openpanel-velero-backups
```

```json
{ "Status": "Enabled" }
```

### S3 — encryption and public access

```bash
aws --endpoint-url http://localhost:4566 --region us-east-1 --no-sign-request \
    s3api get-bucket-encryption --bucket openpanel-velero-backups

aws --endpoint-url http://localhost:4566 --region us-east-1 --no-sign-request \
    s3api get-public-access-block --bucket openpanel-velero-backups
```

### IAM — user, policy, access key

```bash
aws --endpoint-url http://localhost:4566 --region us-east-1 --no-sign-request \
    iam list-users \
    --query 'Users[].{User:UserName,ARN:Arn}' --output table

aws --endpoint-url http://localhost:4566 --region us-east-1 --no-sign-request \
    iam list-attached-user-policies --user-name velero-backup-user \
    --query 'AttachedPolicies[].{Policy:PolicyName,ARN:PolicyArn}' --output table

aws --endpoint-url http://localhost:4566 --region us-east-1 --no-sign-request \
    iam list-access-keys --user-name velero-backup-user \
    --query 'AccessKeyMetadata[].{KeyId:AccessKeyId,Status:Status}' --output table
```

The user is `velero-backup-user`, the policy is `velero-s3-policy`.

### Secrets Manager

```bash
aws --endpoint-url http://localhost:4566 --region us-east-1 --no-sign-request \
    secretsmanager list-secrets \
    --query 'SecretList[].{Name:Name,ARN:ARN}' --output table
```

Expected output: `devops-cluster/sealed-secrets-master-key`. The slot exists but holds no value yet — that's expected.

### Terraform state

```bash
cd terraform/environments/staging && terraform state list
```

A fresh staging apply produces:

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

The lifecycle resource is absent because staging passes `enable_lifecycle = false`. In prod that line shows up as `module.backup_storage.aws_s3_bucket_lifecycle_configuration.velero_backups[0]`.

---

## Make targets

| Target | What it does |
|---|---|
| `make terraform-infra ENV=<staging\|prod>` | `init` + `plan` + `apply` for the chosen environment. |
| `make terraform-status ENV=<staging\|prod>` | Prints `terraform state list` for the chosen environment. |
| `make terraform-destroy ENV=<staging\|prod>` | `destroy -auto-approve`. |
| `make terraform-docs` | Regenerates the per-module README files using `terraform-docs --config terraform/.terraform-docs.yml`. |

---

## Teardown

```bash
make terraform-destroy ENV=staging
docker stop localstack && docker rm localstack
```

Or manually:

```bash
cd terraform/environments/staging && terraform destroy
```

---

## Notes worth keeping in mind

- Staging never reaches AWS. Everything goes through the LocalStack container at `localhost:4566`.
- Prod uses IRSA, so no long-lived IAM keys exist in the cluster or in Git. The role only trusts the Velero ServiceAccount on the `openpanel-prod` EKS cluster.
- `credentials-velero` (written after a staging apply) holds the IAM access key in plaintext. It's git-ignored and must stay that way.
- The `aws_secretsmanager_secret.sealed_secrets_key` slot is provisioned but unused right now. The sealing key is backed up to a local file (`~/.config/openpanel/sealing-key.yaml`) by `scripts/ensure-sealing-key.sh`. Migrating that backup to Secrets Manager is the next planned step.
