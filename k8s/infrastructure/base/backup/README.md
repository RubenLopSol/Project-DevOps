# Backup — Architecture and Operations

---

## What this directory does

This directory defines two backup-related components:

- **MinIO** — an in-cluster S3-compatible object store, deployed only in staging as a local data store for the application (not used as Velero's backup target in staging)
- **Velero** — a Kubernetes backup operator that snapshots namespaces (PVCs, workloads, secrets) and ships them to an S3-compatible backend

**Key distinction:** Velero's backup target differs per environment:

| Environment | Velero backup target | MinIO role |
|---|---|---|
| Staging | LocalStack S3 (host machine, port 4566) | Application object store only |
| Prod | Real AWS S3 bucket | Not deployed (AWS S3 used directly) |

---

## How Velero works

Velero runs as a Deployment inside the `velero` namespace. It uses two CRDs to define what to back up and where to send it:

```
BackupStorageLocation (BSL)
└── tells Velero: "send backups to this S3 bucket at this URL"

Schedule
└── tells Velero: "run a backup on this cron schedule, for these namespaces"
```

When a scheduled backup triggers:

```
Velero reads the Schedule CR
        │
        ▼
Creates a Backup object (snapshot of included namespaces)
        │
        ├── Captures all Kubernetes resource manifests (Deployments, Services, Secrets, ConfigMaps, etc.)
        │
        └── Captures PersistentVolume data (via restic or CSI snapshot)
                │
                ▼
        Uploads the backup archive to the BackupStorageLocation (S3/LocalStack)
                │
                ├── staging: LocalStack S3 running on host:4566
                └── prod:    AWS S3 bucket (openpanel-velero-backups-prod)
```

---

## Directory layout

```
base/backup/
├── kustomization.yaml          ← aggregates minio + velero
├── minio/
│   ├── kustomization.yaml
│   ├── deployment.yaml         ← MinIO server, non-root, health probes
│   ├── service.yaml            ← ClusterIP for API (:9000) and console (:9001)
│   └── pvc.yaml                ← 10Gi PVC for object data
└── velero/
    ├── kustomization.yaml
    ├── backup-location.yaml    ← base BSL: bucket + region (PLACEHOLDER values, overridden by patch)
    └── schedule.yaml           ← daily full backup at 02:00 UTC, 30-day TTL

overlays/staging/velero/
├── kustomization.yaml
└── backup-location-patch.yaml  ← patches BSL: LocalStack URL + path-style

overlays/prod/velero/
├── kustomization.yaml
├── backup-location-patch.yaml  ← patches BSL: real AWS S3, no custom URL
└── velero-schedule-hourly.yaml ← extra prod-only hourly database backup
```

---

## Component connection diagram

### Staging

```
┌─────────────────────────────────────────────────────────┐
│  Minikube cluster                                       │
│                                                         │
│  ┌────────────────┐        ┌──────────────────────────┐ │
│  │  velero ns     │        │  backup ns               │ │
│  │                │        │                          │ │
│  │  Velero pod    │        │  MinIO pod               │ │
│  │  (operator)    │        │  - API:9000              │ │
│  │                │        │  - Console:9001          │ │
│  │  Schedule CR   │        │  - PVC: 10Gi             │ │
│  │  daily@02:00   │        │                          │ │
│  │                │        │  Used by: OpenPanel app  │ │
│  │  BSL CR ───────┼───X    │  (object storage)        │ │
│  │  (not MinIO)   │        │                          │ │
│  └────────────────┘        └──────────────────────────┘ │
│          │                                               │
│          │ backup uploads (port 4566)                    │
└──────────┼──────────────────────────────────────────────┘
           │
           ▼
  ┌──────────────────────┐
  │  Host machine        │
  │                      │
  │  LocalStack:3.4      │
  │  (Docker container)  │
  │                      │
  │  S3 bucket:          │
  │  openpanel-velero-   │
  │  backups             │
  │                      │
  │  Provisioned by:     │
  │  terraform/          │
  │  environments/       │
  │  staging             │
  └──────────────────────┘

  Authentication: IAM user credentials (velero-backup-user)
  from credentials-velero file → Velero secret
```

### Prod

```
┌──────────────────────────────────────────────────────────────┐
│  EKS cluster                                                 │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  velero namespace                                      │  │
│  │                                                        │  │
│  │  Velero pod                                            │  │
│  │  - ServiceAccount annotated with IAM Role ARN (IRSA)  │  │
│  │                                                        │  │
│  │  Schedule CRs:                                         │  │
│  │  - daily-full-backup (02:00 UTC, 30-day TTL)           │  │
│  │    namespaces: openpanel + observability               │  │
│  │  - hourly-database-backup (every hour, 24h TTL)        │  │
│  │    namespace: openpanel                                │  │
│  │    labelSelector: backup=database                      │  │
│  │                                                        │  │
│  │  BSL CR → s3://openpanel-velero-backups-prod           │  │
│  │           region: us-east-1                            │  │
│  └─────────────────────────────┬──────────────────────────┘  │
│                                │                              │
└────────────────────────────────┼──────────────────────────────┘
                                 │ HTTPS (port 443)
                                 ▼
                    ┌────────────────────────┐
                    │  AWS                   │
                    │                        │
                    │  S3 bucket:            │
                    │  openpanel-velero-     │
                    │  backups-prod          │
                    │                        │
                    │  IAM Role (IRSA):      │
                    │  velero-backup-role    │
                    │  Policy: S3 CRUD on    │
                    │  this bucket only      │
                    │                        │
                    │  Provisioned by:       │
                    │  terraform/            │
                    │  environments/prod     │
                    └────────────────────────┘

  Authentication: IRSA — no long-lived credentials
  (EKS OIDC provider maps ServiceAccount → IAM Role)
```

---

## Backup schedules

| Schedule | Cron | Namespaces | Label filter | TTL | Environment |
|---|---|---|---|---|---|
| `daily-full-backup` | `0 2 * * *` (02:00 UTC) | openpanel, observability | none (all resources) | 30 days | staging + prod |
| `hourly-database-backup` | `0 * * * *` (every hour) | openpanel | `backup: database` | 24 hours | prod only |

The hourly schedule uses `labelSelector: matchLabels: backup: database`. Only pods/PVCs with the label `backup: database` are included. Add this label to database StatefulSets/PVCs in the openpanel namespace to opt them into hourly snapshots.

---

## Resources created per environment

### Staging — Kubernetes resources

| Kind | Name | Namespace | Purpose |
|---|---|---|---|
| `Deployment` | `minio` | `backup` | MinIO object store for app use |
| `Service` | `minio` | `backup` | ClusterIP for API (:9000) + console (:9001) |
| `PersistentVolumeClaim` | `minio-data` | `backup` | 10Gi data volume |
| `SealedSecret` | `minio-credentials` | `backup` | MinIO root user/password |
| `Deployment` | `velero` | `velero` | Backup operator |
| `BackupStorageLocation` | `default` | `velero` | Points to LocalStack S3 |
| `Schedule` | `daily-full-backup` | `velero` | Daily full backup at 02:00 UTC |

### Staging — LocalStack resources (via Terraform)

| Resource | Name | Purpose |
|---|---|---|
| S3 bucket | `openpanel-velero-backups` | Velero backup storage |
| IAM user | `velero-backup-user` | Identity for bucket access |
| IAM access key | (written to `credentials-velero`) | Auth credentials for Velero |
| IAM policy | `VeleroBackupPolicy` | S3 CRUD permissions on the bucket |

### Prod — Kubernetes resources

| Kind | Name | Namespace | Purpose |
|---|---|---|---|
| `Deployment` | `velero` | `velero` | Backup operator |
| `BackupStorageLocation` | `default` | `velero` | Points to AWS S3 |
| `Schedule` | `daily-full-backup` | `velero` | Daily full backup at 02:00 UTC |
| `Schedule` | `hourly-database-backup` | `velero` | Hourly DB snapshot |

### Prod — AWS resources (via Terraform)

| Resource | Name | Purpose |
|---|---|---|
| S3 bucket | `openpanel-velero-backups-prod` | Velero backup storage |
| S3 lifecycle rule | 30-day expiry | Auto-delete old backups |
| IAM role | `velero-backup-role` | IRSA identity for Velero pod |
| IAM policy | `VeleroBackupPolicy` | S3 CRUD on this bucket only |

---

## Sealed Secrets key backup (separate from Velero)

The Sealed Secrets controller holds a private key used to decrypt all `SealedSecret` resources in the cluster. If this key is lost, all secrets become unrecoverable.

This is handled separately from Velero because it must survive a full cluster rebuild:

```
make backup-sealing-key
    │
    ▼
kubectl get secret -n sealed-secrets -l sealedsecrets.bitnami.com/sealed-secrets-key
    │
    ▼
Saves key to: .secrets/sealed-secrets-key.yaml (git-ignored)

make restore-sealing-key
    │
    ▼
kubectl apply -f .secrets/sealed-secrets-key.yaml
kubectl rollout restart deployment/sealed-secrets-controller -n sealed-secrets
```

**Store this file out-of-band** (password manager, encrypted USB, separate cloud storage). It is gitignored and must not be committed.

---

## How to trigger a manual backup

```bash
# Trigger an immediate backup (staging)
make backup-run

# Which runs:
velero backup create manual-$(date +%Y%m%d-%H%M%S) \
  --include-namespaces openpanel,observability \
  --storage-location default \
  --wait
```

---

## How to restore

```bash
# List available backups
velero backup get

# Restore from a specific backup
velero restore create --from-backup <backup-name>

# Watch restore progress
velero restore describe <restore-name>
velero restore logs <restore-name>
```

Velero restores all resource manifests and re-provisions PVs from the snapshot. Resources already present in the cluster are not overwritten unless `--existing-resource-policy=update` is passed.

---

## Authentication: staging vs prod

### Staging — IAM user + credentials file

Terraform creates an IAM user in LocalStack and writes credentials to `terraform/environments/staging/credentials-velero`. Velero is installed with:

```bash
velero install \
  --secret-file terraform/environments/staging/credentials-velero \
  ...
```

This mounts the credentials as a Kubernetes Secret `velero-cloud-credentials` in the `velero` namespace, which Velero reads at startup.

### Prod — IRSA (no long-lived credentials)

Terraform creates an IAM Role with a trust policy tied to the EKS OIDC provider. The Velero ServiceAccount is annotated with the Role ARN:

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/velero-backup-role
```

When Velero's pod starts, the EKS pod identity webhook injects a short-lived token. AWS STS exchanges it for temporary credentials valid for the IAM Role. No credentials file is used.

---

## MinIO details (staging only)

MinIO is deployed in the `backup` namespace and serves as an S3-compatible object store for the OpenPanel application (image uploads, user data). It is **not** used as Velero's backup target in staging — that role is filled by LocalStack.

MinIO is hardened:
- Runs as UID 1000, non-root, with `fsGroup: 1000`
- Drops all Linux capabilities
- No privilege escalation
- Liveness probe: `GET /minio/health/live` every 30s
- Readiness probe: `GET /minio/health/ready` every 10s
- Credentials come from a `SealedSecret` (`minio-credentials`)

In prod, MinIO is not deployed. The application uses AWS S3 directly.
