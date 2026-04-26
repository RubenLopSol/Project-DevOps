# ArgoCD

ArgoCD is the GitOps controller. It watches this repository, renders the manifests under `k8s/`, and continuously reconciles the live cluster against them. Manual `kubectl apply` is reserved for exactly one bootstrap step; everything after that is a `git push`.

This directory holds the three pieces that make that work: the chart that installs ArgoCD itself, the `AppProject` that scopes what ArgoCD is allowed to do, and the `Application` CRs that wire each platform component into GitOps.

---

## Directory layout

```
k8s/infrastructure/base/argocd/
├── install/                             # ArgoCD itself, applied once at bootstrap
│   ├── kustomization.yaml               #   helmCharts block — chart, version, releaseName
│   ├── values.yaml                      #   common values (env overlays add their own on top)
│   └── charts/                          #   vendored argo-cd 7.7.0 chart (offline-friendly)
├── projects/
│   ├── kustomization.yaml
│   └── openpanel-project.yaml           # the AppProject — RBAC scope for every child Application
└── applications/                        # the App of Apps — one Application CR per platform component
    ├── kustomization.yaml
    ├── namespaces-app.yaml
    ├── local-path-provisioner-app.yaml
    ├── sealed-secrets-app.yaml
    ├── cert-manager-app.yaml
    ├── argo-rollouts-app.yaml
    ├── velero-operator-app.yaml
    ├── prometheus-app.yaml
    ├── minio-app.yaml
    ├── velero-app.yaml
    ├── loki-app.yaml
    ├── promtail-app.yaml
    ├── tempo-app.yaml
    └── openpanel-app.yaml
```

---

## How ArgoCD comes up: the bootstrap

ArgoCD has a chicken-and-egg problem — something has to install ArgoCD before ArgoCD can install itself. We solve it with a single one-shot script and a single one-shot `kubectl apply`:

```bash
make cluster-up ENV=staging        # wraps scripts/install-argocd.sh
```

`scripts/install-argocd.sh` does five things in order:

1. Verifies `kustomize`, `kubectl` and `helm` are on `PATH` and at acceptable versions.
2. `kustomize build --enable-helm k8s/infrastructure/overlays/<env>/argocd | kubectl apply -f -` — this installs the ArgoCD Helm chart, the `openpanel` `AppProject`, and the env-specific `bootstrap` Application CR.
3. Waits for the `argocd-server` Deployment to roll out.
4. Prints the auto-generated initial admin password.
5. Returns. From this moment on, every other change is a git commit.

The `bootstrap` Application points at `overlays/<env>/argocd/`, which is a Kustomize directory whose `resources:` list pulls in `base/argocd/applications/`. Reconciling `bootstrap` therefore reconciles every child Application. That is the **App of Apps** pattern.

A side effect that is worth calling out: the `argocd` Application itself is in the App of Apps, so once bootstrap is done, ArgoCD upgrades *itself* through GitOps too. Bumping the chart version is a regular PR.

---

## `install/` — ArgoCD itself

Chart: `argoproj/argo-cd` 7.7.0, release name `argocd`, namespace `argocd`. The chart is vendored under `install/charts/argo-cd-7.7.0/` so cluster bring-up does not depend on the upstream Helm repo being reachable at apply time.

The chart renders ~50 objects — `argocd-server`, `argocd-repo-server`, `argocd-application-controller` (the reconciler), `argocd-dex-server` (SSO), `argocd-notifications-controller`, plus the usual ConfigMaps (`argocd-cm`, `argocd-rbac-cm`), the admin Secret (`argocd-secret`), and the Ingress that exposes the UI.

Build it standalone (useful for `kustomize build` lint/CI checks against base values only):

```bash
kustomize build --enable-helm k8s/infrastructure/base/argocd/install
```

In practice always go through an overlay. The base values are deliberately incomplete on hostname / TLS / resources — those have to come from `overlays/staging/argocd/values.yaml` or `overlays/prod/argocd/values.yaml`.

---

## `projects/` — the `openpanel` AppProject

`AppProject` is ArgoCD's RBAC primitive. Every child `Application` declares `spec.project: openpanel`, which means it inherits the rules in this file. An Application that tries to step outside them is rejected by the `argocd-application-controller`, not by Kubernetes — the manifest never even reaches the API server.

The project allows:

| Setting | Value |
|---------|-------|
| Source repos | this Git repo, plus the upstream Helm repos for prometheus-community, grafana, sealed-secrets, argoproj, vmware-tanzu (Velero), jetstack (cert-manager) |
| Destination namespaces | `openpanel`, `observability`, `backup`, `velero`, `sealed-secrets`, `cert-manager`, `argo-rollouts`, `argocd`, `kube-system`, `local-path-storage` |
| Cluster-scoped kinds | `Namespace`, `ClusterRole`, `ClusterRoleBinding`, `CustomResourceDefinition`, `MutatingWebhookConfiguration`, `ValidatingWebhookConfiguration`, `PodSecurityPolicy`, `cert-manager.io/ClusterIssuer` |
| Namespaced kinds (whitelist) | core (`""`), `apps`, `networking.k8s.io`, `batch`, `velero.io`, `rbac.authorization.k8s.io`, `monitoring.coreos.com`, `policy`, `autoscaling`, `bitnami.com` (SealedSecret), `cert-manager.io`, `argoproj.io` (Rollout, AnalysisTemplate, Experiment) |

The whitelist approach is intentional: every group/kind has to be explicitly added, so a chart that suddenly tries to install something exotic fails closed at sync time.

The `bootstrap` Application is the one exception — it is in `project: default` because it is the entry point and exists before the `openpanel` project does.

---

## `applications/` — App of Apps

One Application per platform component, all owned by the `bootstrap` Application via the env overlay. Each carries an `argocd.argoproj.io/sync-wave` annotation that ArgoCD honours: every Application in wave *n* must be `Healthy` + `Synced` before any wave *n+1* sync starts.

| Wave | Application | Watches (staging path) | Deploys into | Why this wave |
|:----:|-------------|------------------------|--------------|---------------|
| **0** | `namespaces` | `k8s/infrastructure/base/namespaces` | cluster-wide | Namespaces have to exist before any later resource references them. |
| **0** | `local-path-provisioner` | `overlays/staging/local-path-provisioner` | `local-path-storage` | StorageClass must exist before any PVC can bind. |
| **1** | `sealed-secrets` | `overlays/staging/sealed-secrets` | `sealed-secrets` | Controller + the SealedSecret CRs that later workloads consume. |
| **1** | `cert-manager` | `overlays/staging/cert-manager` | `cert-manager` | Installs cert-manager CRDs (`Certificate`, `ClusterIssuer`). |
| **1** | `argo-rollouts` | `overlays/staging/argo-rollouts` | `argo-rollouts` | Installs the `Rollout` CRD that the openpanel-api workload uses. |
| **1** | `velero-operator` | `overlays/staging/velero-operator` | `velero` | Installs Velero CRDs (`Backup`, `BackupStorageLocation`, `Schedule`). |
| **2** | `prometheus` | `overlays/staging/observability/kube-prometheus-stack` | `observability` | Needs the namespace and the `local-path` StorageClass. |
| **2** | `minio` | `overlays/staging/minio` | `backup` | Object store that backs Velero's default `BackupStorageLocation`. |
| **2** | `velero` | `overlays/staging/velero` | `velero` | Reconciles `BackupStorageLocation` + `Schedule` against the wave-1 CRDs. |
| **3** | `loki` | `overlays/staging/observability/loki` | `observability` | Logs side of observability — brought up before the app so first-run logs are captured. |
| **3** | `promtail` | `overlays/staging/observability/promtail` | `observability` | Per-node DaemonSet that ships container logs to Loki. |
| **3** | `tempo` | `overlays/staging/observability/tempo` | `observability` | Trace store. Receives OTLP from the api/worker once they start. |
| **4** | `openpanel` | `k8s/apps/overlays/staging` | `openpanel` | Application. Everything it depends on is now Healthy. |

Read the same table off the cluster directly:

```bash
kubectl get applications -n argocd \
  -o custom-columns=NAME:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,PATH:.spec.source.path
```

### Paths are never hardcoded in `base/`

In `base/argocd/applications/*.yaml` you will see `path: PLACEHOLDER`. That is deliberate. Each overlay's `patches/app-env.yaml` does an exact-string replacement to point every Application at the matching env directory (`overlays/staging/...` or `overlays/prod/...`). Neither environment is a hidden default — both have to opt in.

### Sync policy on every child

```yaml
syncPolicy:
  automated:
    prune: true        # (false on argo-rollouts and a couple of others — see below)
    selfHeal: true
    allowEmpty: false
  syncOptions:
    - ServerSideApply=true
    - CreateNamespace=false
```

Two notable exceptions:

- `argo-rollouts-app.yaml` sets `prune: false`. If we let ArgoCD prune the Argo Rollouts controller, it would also delete the `Rollout` CRD, which would in turn cascade-delete every Rollout resource (including `openpanel-api`). The trade is that an explicit removal of the chart from git would not be honoured automatically — you would have to delete the controller by hand. That is the right trade for a CRD-bearing controller.
- The same `prune: false` applies to other CRD-bearing charts where appropriate (cert-manager, sealed-secrets, velero-operator). See each `*-app.yaml` for the per-Application setting.

---

## Why the `helmCharts` block is restated in every overlay

Kustomize cannot strategic-merge a `helmCharts` block from a base into an overlay. There is no patch type for it. The only way to layer overlay-specific Helm values on top of base values is to re-declare the entire chart spec in the overlay and point both files into it:

```text
base/argocd/install/kustomization.yaml          overlays/staging/argocd/kustomization.yaml
─────────────────────────────────────────       ───────────────────────────────────────────────
helmCharts:                                     helmCharts:
  - name: argo-cd                                 - name: argo-cd                       (re-declared)
    repo: argoproj/argo-helm                        repo: argoproj/argo-helm
    version: "7.7.0"                                version: "7.7.0"
    releaseName: argocd                             releaseName: argocd
    namespace: argocd                               namespace: argocd
    valuesFile: values.yaml                         valuesFile: ../../../base/argocd/install/values.yaml
                                                    additionalValuesFiles:
                                                      - values.yaml                    (overlay's own values)
```

Helm merges the two files in order — base first, overlay second, so overlay wins on any conflict (`server.resources.requests.cpu`, `server.ingress.hosts[0]`, etc.). The values still live in one place per environment; only the chart declaration is duplicated.

The same pattern applies to every chart in this project (`kube-prometheus-stack`, `loki`, `promtail`, `tempo`, `cert-manager`, `argo-rollouts`, `sealed-secrets`, `velero-operator`). It is repetitive, but it is the only way Kustomize + Helm interoperate cleanly.

---

## Operational notes

**Watch the platform converge after `make cluster-up`:**

```bash
kubectl get applications -n argocd -w
```

You will see 14 Applications progress through `OutOfSync` → `Synced`/`Healthy` in wave order. Wave 4 (openpanel) is the last to flip; if it stays `Progressing` the issue is almost always a SealedSecret that cannot be decrypted (see [`base/sealed-secrets/README.md`](../sealed-secrets/README.md)).

**Force a re-sync without a git push:**

```bash
argocd app sync openpanel --prune
```

**Diff the live cluster against git:**

```bash
argocd app diff openpanel
```

**Open the UI:**

```bash
# Staging — added to /etc/hosts by scripts/setup-minikube.sh
open http://argocd.local

# Initial admin password (rotated to a real Secret in prod)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```
