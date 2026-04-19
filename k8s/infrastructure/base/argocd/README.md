# ArgoCD — Base and Overlay Structure

---

## What is ArgoCD and how does it work?

### The core idea

ArgoCD is a **GitOps controller** that runs inside your Kubernetes cluster. Its job is simple:
watch a Git repository, and continuously make the cluster look exactly like what Git says it should look like.

Without ArgoCD you would manually run `kubectl apply` every time something changes.
With ArgoCD, you commit to Git and the cluster updates itself automatically.

```
You commit YAML to Git
        │
        ▼
ArgoCD detects the change (polls Git every 3 minutes, or via webhook)
        │
        ▼
ArgoCD runs kustomize build (or helm template) to render the manifests
        │
        ▼
ArgoCD compares rendered manifests against what is live in the cluster
        │
        ├── No difference → cluster is "Synced", nothing to do
        │
        └── Difference found → ArgoCD applies the changes automatically
                               (because automated sync is enabled)
```

If someone manually changes something in the cluster (e.g. `kubectl edit deployment`),
ArgoCD detects the drift and reverts it back to what Git says. This is `selfHeal: true`.

---

### The three ArgoCD concepts this project uses

#### 1. `AppProject` — the permission boundary

Before ArgoCD can deploy anything, it needs to know what it is **allowed** to do.
An `AppProject` defines the rules:

- Which **Git repositories** Applications in this project can pull from
- Which **namespaces** they can deploy resources into
- Which **cluster-scoped resource types** (like `Namespace`, `ClusterRole`) they can create

Think of it as a security fence. An Application that tries to deploy outside these rules
is rejected by ArgoCD. This project has one AppProject named `openpanel`.

```
AppProject "openpanel"
├── Allowed repos:    this Git repo, prometheus helm repo, grafana helm repo
├── Allowed namespaces: openpanel, observability, backup, velero, sealed-secrets, kube-system
└── Allowed cluster resources: Namespace, ClusterRole, CRD, WebhookConfiguration
```

#### 2. `Application` — the GitOps watcher

An `Application` is the main ArgoCD resource. It connects a **Git path** to a **cluster destination**:

```
Application "minio"
├── Source: Git repo → path: k8s/infrastructure/overlays/staging/minio
│           (ArgoCD runs: kustomize build this path)
└── Destination: cluster → namespace: backup
    (ArgoCD applies the rendered manifests here)
```

Each application has a `syncPolicy` that controls:
- `automated.prune: true` — delete resources that were removed from Git
- `automated.selfHeal: true` — revert manual changes back to what Git says
- `sync-wave` annotation — deployment order (see below)

This project has 6 Applications, one per component:
`namespaces` → `sealed-secrets` → `observability` + `minio` + `velero` → `openpanel`

#### 3. Sync waves — deployment order

ArgoCD deploys resources in waves. Wave N does not start until all resources in wave N-1
are `Healthy`. This enforces the correct boot order:

```
Wave 0 → namespaces         (cluster namespaces must exist first)
Wave 1 → sealed-secrets     (controller must be ready before secrets are needed)
Wave 2 → observability      (infrastructure before app)
Wave 2 → minio              (infrastructure before app)
Wave 2 → velero             (infrastructure before app)
Wave 3 → openpanel          (application deployed last, into a fully prepared cluster)
```

---

### The App of Apps pattern

This project uses the **App of Apps** pattern. Instead of manually applying each
`Application` CR with `kubectl apply`, there is one root Application called `bootstrap`
that watches the directory containing all the other Application CRs.

```
You run once:
  kubectl apply -f overlays/staging/argocd/bootstrap-app.yaml
          │
          ▼
ArgoCD creates the "bootstrap" Application
          │
          ▼
bootstrap watches: k8s/infrastructure/overlays/staging/argocd
          │
          ├── finds namespaces-app.yaml   → creates Application "namespaces"
          ├── finds sealed-secrets-app.yaml → creates Application "sealed-secrets"
          ├── finds observability-app.yaml  → creates Application "observability"
          ├── finds minio-app.yaml          → creates Application "minio"
          ├── finds velero-app.yaml         → creates Application "velero"
          └── finds openpanel-app.yaml      → creates Application "openpanel"
                    │
                    ▼
          Each Application then watches its own Git path
          and deploys its own workload independently
```

After the single `kubectl apply` of `bootstrap-app.yaml`, you never need to run
`kubectl apply` again for any Application. Adding a new component is just adding
a new `*-app.yaml` file to Git — ArgoCD picks it up automatically.

---

### How the three directories map to these concepts

| Directory | ArgoCD concept | Applied how |
|---|---|---|
| `base/argocd/install/` | ArgoCD itself (the engine) | `install-argocd.sh` via kustomize build |
| `base/argocd/projects/` | `AppProject` — permission boundary | Part of the overlay, synced by bootstrap app |
| `base/argocd/applications/` | `Application` CRs — GitOps watchers | Part of the overlay, synced by bootstrap app |

The `install/` directory is special: it is only used **once** at bootstrap time to install
ArgoCD itself. After that, ArgoCD manages the `projects/` and `applications/` through GitOps
— any change to those files in Git is picked up and applied automatically.

---

## Directory layout

```
k8s/infrastructure/
├── base/argocd/
│   ├── install/
│   │   ├── kustomization.yaml   ← Helm chart definition (chart, version, repo, releaseName)
│   │   └── values.yaml          ← Common Helm values shared by all environments
│   ├── applications/
│   │   ├── kustomization.yaml
│   │   ├── namespaces-app.yaml
│   │   ├── sealed-secrets-app.yaml
│   │   ├── observability-app.yaml
│   │   ├── minio-app.yaml
│   │   ├── velero-app.yaml
│   │   └── openpanel-app.yaml
│   └── projects/
│       ├── kustomization.yaml
│       └── openpanel-project.yaml
└── overlays/
    ├── staging/argocd/
    │   ├── kustomization.yaml      ← helmCharts re-declared + labels env=staging
    │   ├── values.yaml             ← staging: argocd.local, small resources
    │   ├── bootstrap-app.yaml      ← App of Apps root, applied once manually
    │   └── patches/app-env.yaml    ← empty (base already points to staging)
    └── prod/argocd/
        ├── kustomization.yaml      ← helmCharts re-declared + labels env=prod + patches
        ├── values.yaml             ← prod: real hostname, TLS, larger resources
        ├── bootstrap-app.yaml      ← App of Apps root, applied once manually
        └── patches/app-env.yaml    ← patches all Application paths staging → prod
```

---

## `install/` — ArgoCD Helm chart

**Purpose:** Defines the ArgoCD Helm chart itself: which chart, which version, which Helm repo,
and which release name. Also holds the common values shared across all environments.

**Resources created when built (~50+ objects):**

| Kind | Name | Purpose |
|---|---|---|
| `Deployment` | `argocd-server` | ArgoCD UI and API server |
| `Deployment` | `argocd-repo-server` | Clones Git repos, runs kustomize/helm |
| `Deployment` | `argocd-application-controller` | Reconciles desired vs actual state |
| `Deployment` | `argocd-dex-server` | SSO / OIDC provider |
| `Deployment` | `argocd-notifications-controller` | Slack/email notifications |
| `Service` | one per component | Internal cluster routing |
| `Ingress` | `argocd-server` | Exposes the UI at `argocd.local` (staging) |
| `ConfigMap` | `argocd-cm` | ArgoCD settings (`kustomize.buildOptions`) |
| `ConfigMap` | `argocd-rbac-cm` | RBAC policy rules |
| `Secret` | `argocd-secret` | Admin password, TLS certs |
| `ServiceAccount` | one per component | Pod identity |
| `ClusterRole` / `ClusterRoleBinding` | one per component | Cluster-wide permissions |

**How to build (base values only):**
```bash
kustomize build --enable-helm k8s/infrastructure/base/argocd/install
```

---

## `projects/` — AppProject (RBAC boundary)

**Purpose:** Defines the `AppProject` CRD — an RBAC scope that limits what ArgoCD
Applications belonging to this project are allowed to do. Without it, ArgoCD rejects
any Application that tries to create cluster-scoped resources (Namespaces, CRDs, etc.).

**Resources created:**

| Kind | Name | What it controls |
|---|---|---|
| `AppProject` | `openpanel` | Allowed source repos, destination namespaces, cluster resource types |

The `openpanel` project declares:
- **Source repos:** this Git repository + Prometheus community + Grafana Helm repos
- **Destination namespaces:** `openpanel`, `observability`, `backup`, `velero`, `sealed-secrets`, `kube-system`
- **Cluster-scoped resources allowed:** `Namespace`, `ClusterRole`, `ClusterRoleBinding`, `CustomResourceDefinition`, `MutatingWebhookConfiguration`, `ValidatingWebhookConfiguration`

---

## `applications/` — Application CRs (App of Apps)

**Purpose:** Defines the 6 `Application` CRDs — the GitOps watchers. Each one tells ArgoCD
which Git path to watch and where in the cluster to apply the rendered manifests.
These are **not** the workloads themselves — they are the instructions ArgoCD follows
to continuously reconcile each workload.

**Resources created:**

| Application | Sync wave | Git path watched (staging default) | Deploys to |
|---|---|---|---|
| `namespaces` | 0 | `k8s/infrastructure/base/namespaces` | cluster-wide |
| `sealed-secrets` | 1 | `k8s/infrastructure/overlays/staging/sealed-secrets` | `sealed-secrets` |
| `observability` | 2 | `k8s/infrastructure/overlays/staging/observability` | `observability` |
| `minio` | 2 | `k8s/infrastructure/overlays/staging/minio` | `backup` |
| `velero` | 2 | `k8s/infrastructure/overlays/staging/velero` | `velero` |
| `openpanel` | 3 | `k8s/apps/overlays/staging` | `openpanel` |

**Sync wave ordering** ensures ArgoCD deploys in the correct sequence:
namespaces → sealed-secrets → infrastructure (observability, minio, velero) → application.
ArgoCD waits for all resources in wave N to be `Healthy` before starting wave N+1.

**Paths are never hardcoded in base.** Every env-specific path is set to `PLACEHOLDER`
in the base and overridden by each overlay's `patches/app-env.yaml`. Both staging and
prod explicitly declare their own paths — no environment is a hidden default.

---

## Why the `helmCharts` block is repeated in base and overlay

This is a **Kustomize limitation**. Kustomize cannot merge or extend a `helmCharts`
block from a base into an overlay — there is no strategic merge patch for `helmCharts`.
The only way to add overlay-specific values on top of base values is to re-declare the
full chart spec in the overlay and point to both values files:

```
base/install/kustomization.yaml              overlays/staging/kustomization.yaml
────────────────────────────────             ──────────────────────────────────────────
helmCharts:                                  helmCharts:
  - name: argo-cd           ← same            - name: argo-cd           (re-declared)
    repo: argoproj/...      ← same              repo: argoproj/...
    version: "7.7.0"        ← same              version: "7.7.0"
    releaseName: argocd     ← same              releaseName: argocd
    namespace: argocd       ← same              namespace: argocd
    valuesFile: values.yaml                     valuesFile: ../../../base/argocd/install/values.yaml
                                                additionalValuesFiles:
                                                  - values.yaml         ← staging adds this
```

Helm merges the two values files in order: **base first, overlay second**.
Overlay values win on any conflict (e.g. `server.resources.requests.cpu`).

The base `kustomization.yaml` exists so the chart can be built standalone with only
base values — useful for validation and local testing. In practice, always deploy via
the environment overlay.

The same pattern applies to every chart in this project:
`kube-prometheus-stack`, `loki`, `promtail`, `tempo` all repeat their chart spec
in the staging/prod overlays for exactly the same reason.

---

## How to deploy

```bash
# Staging
./scripts/install-argocd.sh staging

# Prod
./scripts/install-argocd.sh prod
```

The script:
1. Checks prerequisites (`kustomize`, `kubectl`, minimum versions)
2. Renders the overlay: `kustomize build --enable-helm overlays/<ENV>/argocd | kubectl apply`
3. Waits for `argocd-server` rollout
4. Prints the initial admin password
5. Applies `bootstrap-app.yaml` — the single manual step that hands control to ArgoCD

After step 5, ArgoCD watches its own overlay and manages all Application CRs automatically.
No further `kubectl apply` commands are needed — Git commits drive everything.
