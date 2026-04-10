# Verificación Terraform Staging — LocalStack

Verificación manual de Terraform contra LocalStack (emulación local de AWS).

---

## Prerequisitos

LocalStack corriendo en local:

```bash
docker run -d -p 4566:4566 --name localstack localstack/localstack:3
```

Verificar que responde:

```bash
curl http://localhost:4566/_localstack/health
```

**Resultado:**
```json
{
  "services": {
    "s3": "available",
    "iam": "available",
    "secretsmanager": "available",
    ...
  },
  "edition": "community",
  "version": "3.8.1"
}
```

> **Nota:** Usar siempre la imagen `localstack/localstack:3` (community). La imagen sin tag requiere licencia de pago.

---

## Estructura Terraform

```
terraform/
├── modules/
│   ├── backup-storage/   ← S3 + Secrets Manager (compartido entre staging y prod)
│   ├── iam-user/         ← IAM User + Access Key (solo staging/LocalStack)
│   └── iam-irsa/         ← IAM Role con OIDC (solo prod/EKS real)
└── environments/
    ├── staging/          ← Llama a backup-storage + iam-user
    └── prod/             ← Llama a backup-storage + iam-irsa
```

**¿Por qué esta separación?**
- Los módulos contienen el "qué crear" (lógica reutilizable)
- Los environments contienen el "dónde y con qué valores"
- Staging usa IAM User con credenciales estáticas (sencillo, para LocalStack)
- Prod usa IRSA (sin credenciales estáticas, más seguro, requiere EKS con OIDC)

---

## 1. Inicializar Terraform

```bash
cd terraform/environments/staging
terraform init
```

**Resultado:**
```
Initializing modules...
- backup_storage in ../../modules/backup-storage
- velero_iam in ../../modules/iam-user

Initializing provider plugins...
- Installing hashicorp/aws v5.100.0...

Terraform has been successfully initialized!
```

Terraform detecta los dos módulos y descarga el provider AWS.

---

## 2. Plan

```bash
terraform plan
```

**Recursos que va a crear (9 en total):**

| Recurso | Módulo | Descripción |
|---|---|---|
| `aws_s3_bucket.velero_backups` | backup-storage | Bucket S3 `openpanel-velero-backups` |
| `aws_s3_bucket_versioning` | backup-storage | Versionado habilitado |
| `aws_s3_bucket_server_side_encryption_configuration` | backup-storage | Cifrado AES256 |
| `aws_s3_bucket_public_access_block` | backup-storage | Bloqueo acceso público |
| `aws_secretsmanager_secret` | backup-storage | Slot para clave RSA de Sealed Secrets |
| `aws_iam_policy.velero_s3` | iam-user | Policy con permisos S3 mínimos |
| `aws_iam_user.velero` | iam-user | Usuario `velero-backup-user` |
| `aws_iam_user_policy_attachment` | iam-user | Adjunta policy al usuario |
| `aws_iam_access_key.velero` | iam-user | Access Key para el usuario |

---

## 3. Apply

```bash
terraform apply -auto-approve
```

**Resultado:**
```
Apply complete! Resources: 9 added, 0 changed, 0 destroyed.

Outputs:

bucket_arn                    = "arn:aws:s3:::openpanel-velero-backups"
bucket_name                   = "openpanel-velero-backups"
sealed_secrets_key_secret_arn = "arn:aws:secretsmanager:us-east-1:000000000000:secret:devops-cluster/sealed-secrets-master-key-LpEgnH"
velero_access_key_id          = "LKIAQAAAAAAAKXZV7W74"
velero_iam_user               = "velero-backup-user"
velero_secret_access_key      = <sensitive>
velero_install_command        = <<EOT
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket openpanel-velero-backups \
  --backup-location-config region=us-east-1,s3Url=http://localhost:4566,s3ForcePathStyle=true \
  --use-volume-snapshots=false \
  --namespace velero \
  --secret-file ./credentials-velero
EOT
```

---

## Outputs explicados

| Output | Uso |
|---|---|
| `bucket_name` | Nombre del bucket donde Velero guarda los backups |
| `bucket_arn` | ARN del bucket, referenciado en la IAM policy |
| `sealed_secrets_key_secret_arn` | Slot en Secrets Manager para guardar la clave RSA de Sealed Secrets (se rellena después con `make backup-sealing-key`) |
| `velero_access_key_id` | Credencial para el fichero `credentials-velero` |
| `velero_secret_access_key` | Credencial sensible — obtener con `terraform output -raw velero_secret_access_key` |
| `velero_install_command` | Comando completo pre-construido para instalar Velero en el cluster |

---

## Notas importantes

- El estado de Terraform en staging se guarda en `terraform.tfstate` local (gitignored)
- En prod el estado va a un backend S3 remoto con DynamoDB para locking
- `enable_lifecycle = false` en staging porque LocalStack community no soporta lifecycle waiters
- `secret_recovery_window_days = 0` en staging para eliminación inmediata (sin periodo de espera)
- El slot de Secrets Manager se crea vacío — la clave RSA se escribe después cuando el controller de Sealed Secrets está corriendo
