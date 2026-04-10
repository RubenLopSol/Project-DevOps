# Sealed Secrets

---

## Directory layout

```
base/sealed-secrets/
├── kustomization.yaml     ← Helm chart definition (chart, version, repo, releaseName)
└── values.yaml            ← Common Helm values shared by all environments

overlays/staging/sealed-secrets/
├── kustomization.yaml     ← re-declares chart + adds secrets.yaml resource + staging labels
└── secrets.yaml           ← encrypted SealedSecret manifests (safe to commit)

overlays/prod/sealed-secrets/
├── kustomization.yaml     ← re-declares chart + adds secrets.yaml resource + prod labels
└── secrets.yaml           ← encrypted SealedSecret manifests (sealed with prod key)
```

---

## Resources created

`make sealed-secrets ENV=staging` runs in two passes. ArgoCD does the same in one sync because it handles CRDs before custom resources automatically.

### Pass 1 — controller (base overlay, no `secrets.yaml`)

The Helm chart is rendered with `includeCRDs: true` so the CRD comes out first.
`kubectl apply` processes resources in kind order: CRD → ServiceAccount → Roles → Deployment.

| Kind | Name | Namespace | Purpose |
|---|---|---|---|
| `CustomResourceDefinition` | `sealedsecrets.bitnami.com` | cluster-wide | Registers the `SealedSecret` kind — **must exist before pass 2** |
| `ServiceAccount` | `sealed-secrets` | `sealed-secrets` | Pod identity used by the controller |
| `Role` | `sealed-secrets-key-admin` | `sealed-secrets` | Read/write the RSA key Secret in its own namespace |
| `Role` | `sealed-secrets-service-proxier` | `sealed-secrets` | Allow metrics service proxy |
| `ClusterRole` | `secrets-unsealer` | cluster-wide | Read SealedSecrets + write plain Secrets across all namespaces |
| `RoleBinding` | `sealed-secrets-key-admin` | `sealed-secrets` | Binds key-admin Role to ServiceAccount |
| `RoleBinding` | `sealed-secrets-service-proxier` | `sealed-secrets` | Binds proxier Role to ServiceAccount |
| `ClusterRoleBinding` | `sealed-secrets` | cluster-wide | Binds secrets-unsealer ClusterRole to ServiceAccount |
| `Service` | `sealed-secrets` | `sealed-secrets` | Port 8080 — certificate endpoint (`kubeseal --fetch-cert`) |
| `Service` | `sealed-secrets-metrics` | `sealed-secrets` | Port 8081 — Prometheus metrics scrape endpoint |
| `Deployment` | `sealed-secrets` | `sealed-secrets` | Controller pod — holds the RSA private key and watches for SealedSecrets |

After pass 1, the Makefile waits for two conditions before continuing:
1. `kubectl wait --for=condition=Established crd/sealedsecrets.bitnami.com` — CRD accepted by API server
2. `kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sealed-secrets` — controller running

The controller generates a fresh RSA key pair on first boot and stores it as:

| Kind | Name | Namespace | Purpose |
|---|---|---|---|
| `Secret` | `sealed-secrets-key<suffix>` | `sealed-secrets` | RSA private key — auto-generated, never written to disk or Git |

### Pass 2 — SealedSecret resources (env overlay)

Once the CRD is registered and the controller is ready, the full overlay is applied.
This includes the Helm chart resources again (idempotent — all `configured`) plus the six `SealedSecret` objects from `secrets.yaml`.

The controller immediately decrypts each `SealedSecret` and creates a plain `Secret` in the target namespace:

| `SealedSecret` name | Target namespace | Plain `Secret` keys | Consumed by |
|---|---|---|---|
| `postgres-credentials` | `openpanel` | `POSTGRES_USER`, `POSTGRES_PASSWORD` | PostgreSQL, OpenPanel app |
| `redis-credentials` | `openpanel` | `REDIS_PASSWORD` | Redis, OpenPanel app |
| `clickhouse-credentials` | `openpanel` | `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` | ClickHouse, OpenPanel app |
| `openpanel-secrets` | `openpanel` | `DATABASE_URL`, `DATABASE_URL_DIRECT`, `CLICKHOUSE_URL`, `REDIS_URL`, `API_SECRET` | OpenPanel app |
| `grafana-admin-credentials` | `observability` | `admin-user`, `admin-password` | Grafana |
| `minio-credentials` | `backup` | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` | MinIO |

---

## Component and dependency diagram

```
  Git repository
  ┌──────────────────────────────────────────────────┐
  │  base/sealed-secrets/                            │
  │  └── kustomization.yaml (includeCRDs: true)      │
  │                                                  │
  │  overlays/<env>/sealed-secrets/                  │
  │  ├── kustomization.yaml (includeCRDs: true)      │
  │  └── secrets.yaml  ← encrypted, safe to commit   │
  └────────┬─────────────────────┬───────────────────┘
           │ PASS 1              │ PASS 2
           │ kustomize build     │ kustomize build
           │ base/               │ overlays/<env>/
           ▼                     ▼
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  Kubernetes cluster                                                      │
  │                                                                          │
  │  cluster-wide                                                            │
  │  ┌───────────────────────────────────────────────────────────────────┐   │
  │  │  CRD: sealedsecrets.bitnami.com   ← applied first (PASS 1)       │   │
  │  │  ClusterRole: secrets-unsealer                                    │   │
  │  │  ClusterRoleBinding: sealed-secrets                               │   │
  │  └───────────────────────────────────────────────────────────────────┘   │
  │                           ↓ wait: CRD Established                        │
  │  sealed-secrets namespace                                                │
  │  ┌───────────────────────────────────────────────────────────────────┐   │
  │  │  ServiceAccount + Roles + RoleBindings                            │   │
  │  │  Services: sealed-secrets (:8080) + sealed-secrets-metrics (:8081)│   │
  │  │  Deployment: sealed-secrets  ← controller pod                    │   │
  │  │  └── on first boot: generates RSA key pair                       │   │
  │  │      Secret: sealed-secrets-key<hash>  (private key)             │   │
  │  │               ▲ backup-sealing-key   ▼ restore-sealing-key       │   │
  │  └───────────────┼───────────────────────────────────────────────────┘   │
  │                  │          ↓ wait: pod Ready                            │
  │                  │                                                        │
  │                  │   PASS 2: SealedSecret objects applied                │
  │                  │   controller watches for SealedSecrets,               │
  │                  │   decrypts with private key, creates plain Secrets    │
  │                  │                                                        │
  │         ┌────────┴────────────────────────────┐                          │
  │         ▼                                     ▼                          │
  │  openpanel namespace               observability namespace               │
  │  ┌─────────────────────────┐       ┌──────────────────────────┐          │
  │  │  Secret: postgres-creds │       │  Secret: grafana-admin-  │          │
  │  │  Secret: redis-creds    │       │          credentials      │          │
  │  │  Secret: clickhouse-    │       └────────────┬─────────────┘          │
  │  │          creds          │                    ▼                        │
  │  │  Secret: openpanel-     │             Grafana pod (envFrom)           │
  │  │          secrets        │                                             │
  │  └───────────┬─────────────┘       backup namespace                     │
  │              ▼                     ┌──────────────────────────┐          │
  │    OpenPanel pods (envFrom)        │  Secret: minio-creds      │          │
  │    postgres / redis / clickhouse   └────────────┬─────────────┘          │
  │                                                 ▼                        │
  │                                          MinIO pod (envFrom)             │
  └──────────────────────────────────────────────────────────────────────────┘

  AWS Secrets Manager (LocalStack in staging / real AWS in prod)
  ┌────────────────────────────────────────────┐
  │  devops-cluster/sealed-secrets-master-key  │
  │  (full RSA key Secret YAML — for DR only)  │
  └────────────────────────────────────────────┘
          ▲                         │
          │ make backup-sealing-key │ make restore-sealing-key
          └─────────────────────────┘
```

---

## Install dependency order

```
1. make cluster
   └── creates namespace 'sealed-secrets' (wave-0 namespaces)
       make sealed-secrets checks for this and exits early if missing

2. make terraform-infra ENV=staging
   └── provisions the Secrets Manager slot used by make backup-sealing-key

3. make sealed-secrets ENV=staging
   │
   ├── ensure-kustomize
   │   └── auto-installs kustomize v5.4.3 to ~/.local/bin if not found
   │
   ├── PASS 1: kustomize build base/sealed-secrets | kubectl apply
   │   ├── includeCRDs: true → CRD rendered by helm template --include-crds
   │   ├── CRD applied first (kubectl sorts by kind)
   │   ├── then: ServiceAccount, Roles, ClusterRole, Services, Deployment
   │   └── controller pod starts → generates RSA key pair → stores as Secret
   │
   ├── kubectl wait CRD Established   (blocks until API server accepts SealedSecret kind)
   ├── kubectl wait pod Ready         (blocks until controller can decrypt)
   │
   ├── make reseal-secrets (first time only — secrets.yaml does not exist yet)
   │   ├── kubeseal --fetch-cert → fetches cluster public key
   │   └── encrypts each secret → writes overlays/staging/sealed-secrets/secrets.yaml
   │
   └── PASS 2: kustomize build overlays/staging/sealed-secrets | kubectl apply
       ├── Helm chart resources again (idempotent — all "configured")
       ├── SealedSecret objects applied (CRD now registered ✔)
       └── controller decrypts each → creates plain Secret in target namespace

4. make backup-sealing-key            ← run immediately after step 3
   └── exports RSA key to AWS Secrets Manager (LocalStack)
       losing this key = all SealedSecrets permanently unreadable
```

---

## The problem this solves

You need to store passwords in Git so ArgoCD can deploy them to the cluster.
But a regular Kubernetes `Secret` is just base64-encoded — anyone who can read
the repo can decode it instantly.

**Sealed Secrets solves this by encrypting the values with your cluster's RSA
public key.** Only the Sealed Secrets controller running inside your cluster
holds the matching private key and can decrypt them. The encrypted files are
100% safe to commit to Git.

---

## How it works

### Step 1 — You run `make reseal-secrets`

The Makefile takes your plaintext passwords (from `.secrets` or the command
line), creates an in-memory Kubernetes Secret for each one, and pipes it
through `kubeseal`. Kubeseal fetches the cluster's public certificate and
encrypts every value. The result is written to:

```
k8s/infrastructure/overlays/<env>/sealed-secrets/secrets.yaml
```

### Step 2 — You commit and push

The `secrets.yaml` file contains only encrypted blobs — no plaintext anywhere.
Committing it is safe and required for GitOps to work.

### Step 3 — ArgoCD applies it

The `sealed-secrets` ArgoCD Application watches that path and applies the file.
The Sealed Secrets controller sees the `SealedSecret` resources, decrypts them
using its private key, and creates normal Kubernetes `Secret` objects in the
correct namespaces.

### Step 4 — Pods read the secrets normally

Your pods use `envFrom` or `env.valueFrom` to read the plain `Secret` — they
never know Sealed Secrets exists.

```
Developer                      Cluster                          Git
    │                              │                               │
    ├─ make reseal-secrets          │                               │
    │   └─ kubeseal encrypts        │                               │
    │       with cluster pubkey     │                               │
    │                              │                               │
    ├──────────── git push ─────────────────────────────────────►  │
    │                              │                               │
    │                              │  ◄── ArgoCD syncs ────────────┤
    │                              │                               │
    │                    controller decrypts                       │
    │                    └─ creates real Secret                    │
    │                              │                               │
    │                    Pod reads Secret via envFrom              │
```

---

## Full lifecycle

| Step | Command | What happens |
|---|---|---|
| 1 | `make sealed-secrets` | Installs the controller via Helm. Cluster generates a fresh RSA key pair. |
| 2 | `make reseal-secrets ENV=staging` | Encrypts all passwords with the cluster's public key. Writes `secrets.yaml`. |
| 3 | `git commit && git push` | Encrypted secrets land in Git. ArgoCD picks them up. |
| 4 | ArgoCD syncs | Controller decrypts → creates real `Secret` objects in the cluster. |
| 5 | `make backup-sealing-key` | **Do this immediately.** Backs up the private key to AWS Secrets Manager. |
| 6 | New cluster needed | `make restore-sealing-key` → imports the old key. No re-sealing needed. |

---

## The RSA key — where it lives and why it matters

When you install the controller, Kubernetes generates a unique RSA key pair.

- **Public key** — used by `kubeseal` to encrypt. Safe to share.
- **Private key** — stored as a `Secret` in the `sealed-secrets` namespace
  inside the cluster. Never written to disk or Git. Only the controller
  can read it.

**If you destroy the cluster without backing up the private key, all sealed
secrets become permanently unreadable.** You would have to re-seal every
secret from scratch with the new cluster's key.

### How we protect the key

This project uses Terraform to provision a slot in AWS Secrets Manager
(LocalStack in local dev) and the Makefile provides two commands:

```bash
# After every new cluster — back up the key
make backup-sealing-key

# On a new cluster — restore the key before ArgoCD syncs
make restore-sealing-key
```

`backup-sealing-key` exports the controller's TLS secret from Kubernetes and
stores it in AWS Secrets Manager under `devops-cluster/sealed-secrets-master-key`.

`restore-sealing-key` pulls it back, applies it to the new cluster, and
restarts the controller so it picks up the restored key. All existing
`secrets.yaml` files decrypt immediately — no re-sealing needed.

### Verify the key was stored (staging / LocalStack)

After running `make backup-sealing-key`, confirm the value landed in LocalStack:

```bash
# Check the secret exists
aws secretsmanager list-secrets \
  --endpoint-url http://localhost:4566 \
  --region us-east-1 \
  --query 'SecretList[].Name'

# Inspect the stored value (first 5 lines — should be YAML starting with apiVersion: v1)
aws secretsmanager get-secret-value \
  --endpoint-url http://localhost:4566 \
  --secret-id devops-cluster/sealed-secrets-master-key \
  --region us-east-1 \
  --query SecretString \
  --output text | head -5
```

Expected output for the second command:
```
apiVersion: v1
items:
- apiVersion: v1
  kind: Secret
  metadata:
```

If you get `ResourceNotFoundException`, the backup failed — re-run `make backup-sealing-key`.

---

## Per-environment setup

Each environment has its own encrypted `secrets.yaml` because:

- Every cluster generates a **different RSA key pair** — staging blobs cannot
  be decrypted by the prod controller, and vice versa.
- Prod should use **strong, unique passwords**, not the dev defaults.

```
overlays/
  staging/sealed-secrets/secrets.yaml   ← sealed with staging cluster key
  prod/sealed-secrets/secrets.yaml      ← sealed with prod cluster key
```

### Sealing for staging (first time or after cluster recreate)

```bash
# Uses dev defaults — fine for local Minikube
make reseal-secrets ENV=staging

# Or with custom passwords
make reseal-secrets ENV=staging POSTGRES_PASSWORD=mypassword REDIS_PASSWORD=mypassword
```

### Sealing for prod

```bash
# Switch to the prod cluster first
kubectl config use-context prod-cluster

make reseal-secrets ENV=prod \
  POSTGRES_PASSWORD=<strong-password> \
  REDIS_PASSWORD=<strong-password> \
  CLICKHOUSE_PASSWORD=<strong-password> \
  API_SECRET=$(openssl rand -hex 32) \
  GRAFANA_PASSWORD=<strong-password> \
  MINIO_PASSWORD=<strong-password>

git add k8s/infrastructure/overlays/prod/sealed-secrets/secrets.yaml
git commit -m "seal: regenerate prod secrets"
git push
```

---

## Where secrets land — one namespace per app

The controller lives in the `sealed-secrets` namespace, but the decrypted
`Secret` objects it creates land in the **namespace declared in each
SealedSecret resource** — not in `sealed-secrets`. The controller reaches
across namespaces to create them exactly where each app expects to find them.

This is the only way it can work: a pod can only read Secrets in its own
namespace. A secret in the wrong namespace is invisible to the app.

```
sealed-secrets namespace          openpanel namespace
┌─────────────────────┐           ┌──────────────────────────────┐
│  controller pod     │  decrypt  │  postgres-credentials Secret │
│  (holds private key)│ ────────► │  redis-credentials Secret    │
│                     │           │  clickhouse-credentials       │
│                     │           │  openpanel-secrets Secret     │
└─────────────────────┘           └──────────────────────────────┘
                                  observability namespace
                                  ┌──────────────────────────────┐
                                  │  grafana-admin-credentials   │
                                  └──────────────────────────────┘
                                  backup namespace
                                  ┌──────────────────────────────┐
                                  │  minio-credentials Secret    │
                                  └──────────────────────────────┘
```

## Secrets in this project

| # | Secret name | Lands in namespace | What it contains |
|---|---|---|---|
| 1 | `postgres-credentials` | `openpanel` | `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| 2 | `redis-credentials` | `openpanel` | `REDIS_PASSWORD` |
| 3 | `clickhouse-credentials` | `openpanel` | `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` |
| 4 | `openpanel-secrets` | `openpanel` | `DATABASE_URL`, `DATABASE_URL_DIRECT`, `CLICKHOUSE_URL`, `REDIS_URL`, `API_SECRET` |
| 5 | `grafana-admin-credentials` | `observability` | `admin-user`, `admin-password` |
| 6 | `minio-credentials` | `backup` | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` |

All six are generated by `make reseal-secrets` and stored in one file per
environment — `overlays/<env>/sealed-secrets/secrets.yaml`.

---

## ArgoCD integration

The `sealed-secrets` ArgoCD Application (`argocd/applications/sealed-secrets-app.yaml`)
manages both the controller and the SealedSecret resources from one path:
`overlays/staging/sealed-secrets/`.

**Why `--enable-helm` is required**
The overlay uses `helmChartInflationGenerator` (`helmCharts:` block in
kustomization.yaml) to render the controller chart inline. ArgoCD must be told
to pass `--enable-helm` when running `kustomize build`, otherwise the chart
block is silently ignored and the controller is never installed.

**Why `prune: false`**
ArgoCD will never automatically delete a Secret, even if you remove it from
`secrets.yaml`. Secrets hold live credentials — an accidental prune would
break running pods immediately. Deletions must always be done intentionally
by hand.

**AppProject permissions**
The ArgoCD AppProject (`openpanel-project.yaml`) allows deployments to four
namespaces — `sealed-secrets` (controller), `openpanel`, `observability`, and
`backup` (decrypted secrets). It also whitelists the `bitnami.com` API group
so ArgoCD can apply `SealedSecret` resources. Without these entries ArgoCD
would reject the sync.

---

## Troubleshooting

**"error decrypting" when the controller tries to apply secrets.yaml**
The cluster's private key does not match the key used to seal the file.
Either restore the original key or re-seal for the current cluster:
```bash
make restore-sealing-key        # if you have a backup
make reseal-secrets ENV=staging # if you need to start fresh
```

**`kubeseal: cannot fetch certificate`**
The controller pod is not running. Check:
```bash
kubectl get pods -n sealed-secrets
kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets
```

**Secrets exist in cluster but pods can't read them**
Check that the namespace in the `SealedSecret` manifest matches where the pod
is running. Sealed Secrets are namespace-scoped — a secret sealed for
`openpanel` cannot be decrypted and applied to `observability`.
