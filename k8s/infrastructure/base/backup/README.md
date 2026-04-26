# Backup

Velero is the cluster's backup operator: it captures Kubernetes manifests + PV data on a schedule and ships them to an S3-compatible bucket. This directory wires up the operator (`velero-operator/`), the runtime CRs (`velero/`), and the in-cluster object store that backs Velero in staging (`minio/`).

The backend is environment-specific. Staging keeps the entire backup loop inside the cluster (so a reviewer can run `make cluster-up` and have working DR without an AWS account); prod ships to a real S3 bucket with IRSA-issued credentials.

| Environment | Velero backup target | Auth |
|-------------|----------------------|------|
| Staging | in-cluster MinIO at `minio.backup.svc.cluster.local:9000` | `minioadmin` / `minioadmin` (rotatable via the `minio-credentials` SealedSecret) |
| Prod | real AWS S3 (`openpanel-velero-backups-prod`) | IRSA — no static credentials in the cluster |

---

## Directory layout

```
k8s/infrastructure/base/backup/
├── kustomization.yaml              # aggregates minio + velero
├── minio/
│   ├── kustomization.yaml
│   ├── deployment.yaml             # MinIO server, non-root, healthcheck probes
│   ├── service.yaml                # ClusterIP — :9000 (S3 API), :9001 (console)
│   └── pvc.yaml                    # 10 Gi default (overridden per env)
├── velero-operator/                # deferred to the velero-operator app — chart lives here
│   └── kustomization.yaml          #   re-declared in each overlay with env-specific values
└── velero/
    ├── kustomization.yaml
    ├── backup-location.yaml        # base BackupStorageLocation (provider only — bucket patched per env)
    └── schedule.yaml               # daily-full-backup · 02:00 UTC · 30-day retention

k8s/infrastructure/overlays/staging/
├── minio/                          # PVC patched to 5 Gi
└── velero/
    ├── backup-location-patch.yaml  # s3Url → minio.backup.svc:9000, s3ForcePathStyle: true
    └── kustomization.yaml

k8s/infrastructure/overlays/prod/
├── minio/                          # PVC patched to 50 Gi (still synced — bucket unused in prod)
└── velero/
    ├── backup-location-patch.yaml  # bucket → openpanel-velero-backups-prod, region us-east-1
    ├── velero-schedule-hourly.yaml # extra prod-only Schedule: hourly DB-only snapshot
    └── kustomization.yaml
```

---

## Architecture — staging

![Backup architecture, staging](../../../docs/screenshots/diagrams/backup-staging.png)

In staging Velero ships everything in-cluster to MinIO. The `Schedule` produces `Backup` CRs at the cron times below; the Velero controller responds to each by tarring the included namespaces and PUT-ing them to the bucket named `velero-backups` inside MinIO. The `BackupStorageLocation` named `default` is the link between the two — the `s3Url` is the cluster-internal Service DNS for MinIO.

MinIO authentication for Velero comes from a static credentials block in the `velero-operator` Helm values (`aws_access_key_id=minioadmin`, `aws_secret_access_key=minioadmin`). MinIO itself reads its root user from the `minio-credentials` SealedSecret on first boot. **The two have to match** — overriding `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` via `make reseal` without updating the velero-operator values triggers an `InvalidAccessKeyId` on the first backup attempt.

## Architecture — prod

![Backup architecture, prod](../../../docs/screenshots/diagrams/backup-prod.png)

In prod the backup target is a real S3 bucket and there are no static credentials in the cluster. Velero's ServiceAccount carries the `eks.amazonaws.com/role-arn` annotation that points at the `velero-prod-role` IAM role provisioned by Terraform. The EKS pod-identity webhook injects a short-lived OIDC token; Velero exchanges it for temporary STS credentials on every API call. The MinIO Application is still synced (one set of manifests, both environments) but the bucket is never written to.

Prod adds a second `Schedule` — `hourly-database-backup` — that runs every hour and only includes resources in the `openpanel` namespace carrying the label `backup: database`. It is short-lived (24 h TTL) and exists so an RPO window of an hour is achievable for the databases without exploding storage cost on the rest of the namespace.

---

## Schedules

| Schedule | Cron | Includes | Retention | Where it lives |
|----------|-----|----------|-----------|---------------|
| `daily-full-backup` | `0 2 * * *` (02:00 UTC) | namespaces `openpanel` + `observability`, all resources | 720 h (30 days) | `base/backup/velero/schedule.yaml` — applied in both envs |
| `hourly-database-backup` | `0 * * * *` (every hour) | namespace `openpanel`, label `backup: database` | 24 h | `overlays/prod/velero/velero-schedule-hourly.yaml` — prod only |

Anything that should be hourly-snapshotted in prod has to carry `backup: database` on its pod template (so the PVC inherits it). The Postgres / ClickHouse / Redis StatefulSets in `k8s/apps/base/openpanel/` already have it.

---

## Resources reconciled, by environment

### Staging

In-cluster:

| Kind | Name | Namespace | Notes |
|------|------|-----------|-------|
| `Deployment` | `minio` | `backup` | non-root, drops all caps, `runAsUser: 1000`, liveness on `/minio/health/live`, readiness on `/minio/health/ready` |
| `Service` | `minio` | `backup` | ClusterIP, `:9000` (S3 API) + `:9001` (console) |
| `PersistentVolumeClaim` | `minio-data` | `backup` | 5 Gi, `local-path` StorageClass |
| `SealedSecret` | `minio-credentials` | `backup` | seeds `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` |
| `Deployment` | `velero` | `velero` | from the velero-operator Helm chart |
| `BackupStorageLocation` | `default` | `velero` | points at MinIO |
| `Schedule` | `daily-full-backup` | `velero` | from the base manifest |

In LocalStack (provisioned by `terraform/environments/staging/`):

| Resource | Name |
|----------|------|
| S3 bucket | `openpanel-velero-backups` *(present but unused — Velero in staging targets MinIO)* |
| IAM user | `velero-backup-user` |
| IAM access key | written to `terraform/environments/staging/credentials-velero` (gitignored) |
| IAM policy | `VeleroBackupPolicy` — S3 CRUD on the bucket only |

### Prod

In-cluster:

| Kind | Name | Namespace |
|------|------|-----------|
| `Deployment` | `velero` | `velero` |
| `BackupStorageLocation` | `default` | `velero` |
| `Schedule` | `daily-full-backup` | `velero` |
| `Schedule` | `hourly-database-backup` | `velero` |

In AWS (provisioned by `terraform/environments/prod/`):

| Resource | Name |
|----------|------|
| S3 bucket | `openpanel-velero-backups-prod` |
| Lifecycle rule | 30-day expiry (defence-in-depth alongside Velero's `ttl`) |
| IAM role | `velero-prod-role` (OIDC trust scoped to the `velero` ServiceAccount) |
| IAM policy | `VeleroBackupPolicy` — S3 CRUD on this bucket only |

---

## Operations

### Trigger an ad-hoc backup

`scripts/backup-restore.sh` is the operational CLI — it shells out to `velero` with the right flags so you don't have to remember them.

```bash
# Full backup of the openpanel namespace (default)
./scripts/backup-restore.sh backup

# Full backup of a different namespace
./scripts/backup-restore.sh backup observability

# Database-only backup (label-selected)
./scripts/backup-restore.sh backup-db
```

Each invocation creates a `Backup` CR named `manual-<namespace>-<YYYYMMDD-HHMMSS>` so it never collides with a scheduled run.

### Restore from a backup

```bash
# List what's available
./scripts/backup-restore.sh list

# Restore by name
./scripts/backup-restore.sh restore manual-openpanel-20260101-143000
```

Behind the scenes that runs `velero restore create --from-backup <name>` and then watches `velero restore describe` until it terminates. Resources already present in the target namespace are not overwritten; pass `--existing-resource-policy=update` to `velero restore create` if you need to overwrite.

### Run a DR drill end-to-end

```bash
# Start a backup, wait for completion
./scripts/backup-restore.sh backup
./scripts/backup-restore.sh list

# Wipe the openpanel namespace (or the whole cluster — make cluster-down)
kubectl delete ns openpanel

# Restore
./scripts/backup-restore.sh restore <backup-name>
```

`make cluster-up` works after a `cluster-down` because the Sealed Secrets keypair is preserved in `~/.config/openpanel/sealing-key.yaml` (see [`base/sealed-secrets/README.md`](../sealed-secrets/README.md) for the full key-management story).

### Inspect Velero state directly

```bash
velero backup get
velero backup describe <name> --details
velero schedule get
velero backup-location get
```

---

## Sealed Secrets keypair backup (handled separately)

The Sealed Secrets controller's RSA private key is **not** backed up by Velero. If it is lost the cluster can never decrypt the `SealedSecret` CRs in git, so it is treated as a separate operational artefact:

- `scripts/ensure-sealing-key.sh` saves a copy to `~/.config/openpanel/sealing-key.yaml` the first time it runs against a fresh cluster, and applies that file on every subsequent `make cluster-up` so the same key is reused.
- The file is gitignored. It belongs in a password manager, an encrypted USB, or another out-of-band store. Losing the laptop and the USB at the same time means re-running `make reseal` against the new keypair (recoverable, just inconvenient).

Full lifecycle and recovery story: [`base/sealed-secrets/README.md`](../sealed-secrets/README.md).

---

## MinIO hardening notes

The MinIO Deployment ships with a security context that satisfies the `kube-linter` gate in `ci-validate.yml`:

- `runAsNonRoot: true`, `runAsUser: 1000`, `fsGroup: 1000`
- `capabilities.drop: ["ALL"]`
- `allowPrivilegeEscalation: false`
- `readOnlyRootFilesystem: true` is *not* set — MinIO writes to `/data` from PVC
- Liveness probe `GET /minio/health/live` every 30 s
- Readiness probe `GET /minio/health/ready` every 10 s

Console is exposed on `:9001` for staging troubleshooting; the Service is `ClusterIP`, so reaching it is a `kubectl port-forward -n backup svc/minio 9001:9001`. Username / password come from the `minio-credentials` SealedSecret.
