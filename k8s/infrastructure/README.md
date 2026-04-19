# Infrastructure layer

Everything in `k8s/infrastructure/` is *platform* — the cluster-wide controllers, storage, secrets, backups, and GitOps plumbing that exist so the OpenPanel application (`k8s/apps/`) can run. This layer is installed once per cluster and reconciled continuously by ArgoCD.

Observability (Prometheus, Loki, Promtail, Tempo, Grafana) is also installed from this tree but is documented separately — see `observability/README.md` (todo).

---

## 1. Layout

```
k8s/infrastructure/
├── base/                         # env-neutral definitions
│   ├── argocd/
│   │   ├── install/              # ArgoCD Helm chart + base values
│   │   ├── projects/             # AppProject RBAC scope
│   │   └── applications/         # One Application CR per platform component
│   ├── namespaces/               # All cluster namespaces, declared once
│   ├── local-path-provisioner/   # StorageClass "local-path" for PVCs
│   ├── sealed-secrets/           # Controller for sealed SealedSecret → Secret
│   ├── cert-manager/             # Controller + CRDs for TLS certificates
│   ├── backup/
│   │   ├── minio/                # S3-compatible object store (backup target)
│   │   ├── velero-operator/      # Installs Velero controller
│   │   └── velero/               # BackupStorageLocation + Schedule
│   └── observability/            # Prometheus, Loki, Promtail, Tempo — see obs doc
└── overlays/
    ├── staging/                  # per-component kustomize overlays
    └── prod/                     # same set, prod-tuned (replicas, resources, issuers)
```

All Helm-based components follow the same pattern: chart values in `base/<component>/values.yaml`, and an overlay re-declares the chart with a pointer back to those base values (Kustomize cannot merge `helmCharts` blocks, so the full chart spec is restated in each overlay — values still live in one place).

---

## 2. How it's deployed (App-of-Apps + sync waves)

The cluster boots via `scripts/install-argocd.sh <ENV>`:

1. Renders the env overlay (`overlays/<env>/argocd/`) with `kustomize build --enable-helm` and applies it. That installs ArgoCD itself from the Helm chart.
2. Applies the `AppProject` (`base/argocd/projects/openpanel-project.yaml`) which defines the RBAC scope for every Application CR.
3. Applies the bootstrap Application (`overlays/<env>/argocd/bootstrap-app.yaml`). That Application owns `base/argocd/applications/`, i.e. the set of Application CRs below — this is the **App-of-Apps** pattern.

From that moment on, changes pushed to the repo are auto-reconciled. Nothing on the platform is kubectl-applied imperatively after bootstrap.

### Sync waves

Each Application carries an `argocd.argoproj.io/sync-wave` annotation so waves 0 → 4 complete before the next starts. Lower waves finish first.

```
wave 0 ─── namespaces, local-path-provisioner
            │
            ▼
wave 1 ─── sealed-secrets, cert-manager, velero-operator   (controllers + CRDs)
            │
            ▼
wave 2 ─── prometheus, minio, velero                       (consume wave-1 CRDs + storage)
            │
            ▼
wave 3 ─── loki, promtail, tempo                           (observability scrape/ship layer)
            │
            ▼
wave 4 ─── openpanel                                       (application; everything ready)
```

| Wave | Apps | Why this wave |
|------|------|---------------|
| 0 | `namespaces`, `local-path-provisioner` | Namespaces must exist before any app declares itself into one; the StorageClass must exist before any PVC is bound. |
| 1 | `sealed-secrets`, `cert-manager`, `velero-operator` | Controllers with CRDs + webhooks. Nothing in later waves can reference their CRs until they're healthy. |
| 2 | `prometheus`, `minio`, `velero` | Depend on wave-1 pieces: Velero needs its operator + object-store; Prometheus needs the monitoring namespace + storage. |
| 3 | `loki`, `promtail`, `tempo` | Observability scrape / ship targets — brought up before the application so first-run telemetry isn't lost. |
| 4 | `openpanel` | Application layer. By the time this syncs: namespaces, storage, secrets controller, TLS controller, backups, and observability are all live. |

The sync-wave fields are visible in the CR metadata — `grep "sync-wave" k8s/infrastructure/base/argocd/applications/*.yaml`.

---

## 3. Components

Everything below is applied as an ArgoCD Application; the table lists each one with what it deploys and how the rest of the project consumes it.

### 3.1 Namespaces (`namespaces`)

Single flat manifest declaring every namespace the platform touches. No chart. Held in its own Application so it always reconciles to match what the platform expects — a deleted namespace is re-created by ArgoCD's self-heal.

Namespaces declared: `openpanel`, `observability`, `argocd`, `backup`, `velero`, `sealed-secrets`, `cert-manager`.

### 3.2 local-path-provisioner (`local-path-provisioner`)

Rancher's [local-path-provisioner](https://github.com/rancher/local-path-provisioner) installed cluster-wide. Provides the `local-path` StorageClass that all stateful workloads bind to.

**Used by:** postgres, clickhouse, redis (via `volumeClaimTemplates`), prometheus, loki, minio, tempo. The `standard` StorageClass shipped with minikube is replaced because its provisioner pins all PVCs to the control-plane node — `local-path` binds each PVC to the node where the pod ran, keeping data local to that node across restarts.

### 3.3 ArgoCD itself (`base/argocd/install/`)

Installed imperatively by `scripts/install-argocd.sh` before the App-of-Apps takes over. Chart: `argo/argo-cd` v7.7.0. Base `values.yaml` holds common settings; each overlay (`overlays/staging/argocd/values.yaml` vs. `overlays/prod/argocd/values.yaml`) layers env-specific tuning — hostname, TLS, resource requests/limits.

**Used by:** every other component on this page (every one is an ArgoCD Application).

### 3.4 Sealed Secrets (`sealed-secrets` — wave 1)

Chart: `bitnami-labs/sealed-secrets` v2.16.1, namespace `sealed-secrets`. One replica; holds the cluster's sealing key in memory.

The sealing flow is: developer runs `kubeseal` locally against a plain Kubernetes Secret → produces a `SealedSecret` CR → committed to git → cluster's controller decrypts and emits a regular Secret in the target namespace. Plain Secrets never touch git.

**Used by:** `openpanel-secrets` (DATABASE_URL, CLICKHOUSE_URL, REDIS_URL, session keys), `postgres-credentials`, `redis-credentials`, `clickhouse-credentials`. All consumed by app pods via `envFrom`/`secretKeyRef`. Regenerate with `make reseal-secrets ENV=<env>`.

### 3.5 cert-manager (`cert-manager` — wave 1)

Chart: `jetstack/cert-manager` v1.16.2, namespace `cert-manager`. Installs the controller, webhook, cainjector, and the full CRD set (Certificate, ClusterIssuer, Order, Challenge, …).

The overlay contributes a single `ClusterIssuer` named `openpanel-selfsigned` — staging uses `selfSigned: {}`, the prod overlay keeps the same name but has a `TODO` marker to swap in ACME/Let's Encrypt. The issuer name is the stable contract; every `Certificate` in `k8s/apps/` references it.

**Used by:** `k8s/apps/base/openpanel/certificate.yaml` — a `Certificate` resource that requests a cert with SAN `openpanel.local` + `api.openpanel.local`, 90-day lifetime, auto-renew at 60 days remaining. cert-manager reconciles it into a Secret named `openpanel-tls`, which the ingress references in its `tls:` block. The TLS-termination flow in the cluster is therefore **fully declarative, fully reconciled, and no shell step is ever required to bootstrap or rotate certs**.

Other consumers (e.g. the observability stack if/when Grafana Ingress goes TLS) can add their own `Certificate` resources referencing the same `ClusterIssuer`.

### 3.6 MinIO (`minio` — wave 2)

Deployed from in-tree manifests (not a Helm chart) at `base/backup/minio/`: Deployment + PVC + ClusterIP Service. S3-compatible object storage scoped to the cluster.

**Used by:** Velero's `BackupStorageLocation` — every scheduled backup lands in a `velero/` bucket inside MinIO. Keeping the backup target in-cluster makes the staging lifecycle fully self-contained (no AWS reachability required); prod overlays would point Velero at real S3 instead.

### 3.7 Velero operator + Velero (`velero-operator` wave 1, `velero` wave 2)

Two-stage install. The operator (`base/backup/velero-operator/`) is a Helm chart that installs Velero's CRDs and controller. Once those CRDs exist, the `velero` Application applies the actual configuration: a `BackupStorageLocation` pointing at MinIO, and a `Schedule` CR for recurring backups.

**Used by:** operational DR. The whole openpanel namespace (workloads + PVCs) is included in the scheduled backup; `scripts/backup-restore.sh` drives restores during drills.

### 3.8 Observability stack (wave 2–3, separate doc)

Installed from this tree (`base/observability/kube-prometheus-stack`, `loki`, `promtail`, `tempo`) but documented in its own README — covers scrape targets, ServiceMonitors, retention, alerts, dashboards. Come back here for the one-line summary: **Prometheus** scrapes workload metrics including sidecar exporters (postgres-exporter, redis-exporter) and native ClickHouse metrics; **Loki** stores logs shipped by **Promtail** (DaemonSet); **Tempo** stores traces. Grafana is bundled inside `kube-prometheus-stack`.

---

## 4. Deploying

```bash
# 1. Stand up minikube and configure /etc/hosts
make minikube-up                   # 3-node cluster, local-path, ingress-nginx

# 2. Install ArgoCD + bootstrap App-of-Apps (one shot)
make cluster-up ENV=staging        # or: ./scripts/install-argocd.sh staging

# 3. From this point ArgoCD reconciles everything above
kubectl get applications -n argocd -w
```

Re-pointing to prod is purely a matter of re-running `make cluster-up ENV=prod`. No per-component step.

---

## 5. Environment differences at a glance

| Concern | Staging | Prod |
|---------|---------|------|
| Storage | `local-path` (node-local) | `local-path` (same — would swap for CSI+EBS on real cloud) |
| TLS issuer | `selfSigned` ClusterIssuer | Same name, swap `spec` for ACME (HTTP-01 or DNS-01) |
| Backup target | in-cluster MinIO | real S3 bucket (`BackupStorageLocation` patched in overlay) |
| ArgoCD hostname | `argocd.local` | prod FQDN with real cert |
| Replica counts | 1 per controller | HA (2–3 per controller) |
| Ingress TLS | self-signed, browser warning | trusted CA, no warning |

Every one of those swaps lives in `overlays/<env>/` — base never encodes env-specific values.

---

## 6. What's deliberately *not* in this layer

- **Application workloads.** The OpenPanel API, dashboard, worker, and databases live in `k8s/apps/` and are owned by the `openpanel` ArgoCD Application (wave 4). This layer stops at the plumbing.
- **Terraform-provisioned AWS resources.** S3 bucket for backups, IAM for Velero, Secrets Manager bootstrap secret — see `terraform/README.md`. Terraform handles the pre-cluster estate; Helm/Kustomize handle the in-cluster estate. The two meet at the IAM credentials Velero consumes.
- **Secret material.** Only `SealedSecret` CRs live in git. The plain values are held by the sealed-secrets controller (and the human who ran `kubeseal`).
