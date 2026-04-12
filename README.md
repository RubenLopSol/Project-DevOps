# Project-DevOps

Production-grade DevOps platform built as a Master's final project. Deploys [OpenPanel](https://openpanel.dev) — an open-source analytics platform — using a full GitOps pipeline with Kubernetes, ArgoCD, Terraform, and a complete observability stack.

---

## Submodule Setup

The `openpanel/` directory is a **git submodule** pointing to a fork of the OpenPanel source code. It is not committed as files — git only tracks a single pointer (commit SHA) to the external repo.

### After cloning this repo

The `openpanel/` folder will be empty. Run:

```bash
git submodule update --init
```

This fetches the pinned commit from the fork and populates `openpanel/`. The contents are **not tracked by this repo** — git ignores everything inside `openpanel/` and only records the pointer. You will not accidentally commit application source files.

To clone and populate in one step:

```bash
git clone --recurse-submodules git@github.com:RubenLopSol/Project-DevOps.git
```

### Bumping to a newer openpanel commit

When new changes are pushed to the openpanel fork and you want to pick them up:

```bash
cd openpanel
git pull origin main          # fetch latest commit from the fork

cd ..
git add openpanel             # stages the updated pointer (one line change)
git commit -m "chore: bump openpanel submodule to latest"
git push origin master        # triggers Gate 1 → Gate 2 → Gate 3 → deploy
```

CI/CD handles the submodule automatically — workflows that need the source code (`ci-validate.yml`, `ci-build-publish.yml`) run `git submodule update --init` behind the scenes via `submodules: true` in the checkout step.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        LOCAL DEVELOPMENT                            │
│                                                                     │
│   docker-compose.yml (11 services)                                  │
│                                                                     │
│   ┌──────────┐  ┌──────────┐  ┌─────────────┐                      │
│   │ postgres │  │  redis   │  │ clickhouse  │  ← data stores       │
│   └────┬─────┘  └────┬─────┘  └──────┬──────┘                      │
│        └─────────────┴───────────────┘                              │
│                          │                                          │
│                    ┌─────▼──────┐                                   │
│                    │  migrate   │  ← Prisma migrations (init job)   │
│                    └─────┬──────┘                                   │
│                          │                                          │
│          ┌───────────────┼──────────────────┐                       │
│          │               │                  │                       │
│     ┌────▼────┐    ┌──────▼─────┐    ┌──────▼──────┐               │
│     │   api   │    │   worker   │    │  dashboard  │               │
│     │ :3333   │    │   :3334    │    │   :3000     │               │
│     └────┬────┘    └──────┬─────┘    └─────────────┘               │
│          │                │                                         │
│    Redis queue      BullMQ consumer                                 │
│    (buffer)         → ClickHouse batch write                        │
│                                                                     │
│   ┌────────────┐  ┌──────┐  ┌─────────┐  ┌─────────┐              │
│   │ prometheus │  │ loki │  │promtail │  │ grafana │  ← observ.   │
│   │   :9090    │  │:3100 │  │(no port)│  │  :3001  │              │
│   └────────────┘  └──────┘  └─────────┘  └─────────┘              │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                     KUBERNETES (STAGING / PROD)                     │
│                                                                     │
│  Minikube (3 nodes)  /  EKS (prod)                                  │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  ArgoCD — App of Apps pattern                               │   │
│  │                                                             │   │
│  │  bootstrap-app → applications/ → syncs all components      │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  Namespaces: openpanel | monitoring | logging | argocd |            │
│              velero | sealed-secrets | storage                      │
│                                                                     │
│  Blue-Green Deployment (API)                                        │
│  ┌──────────────────────────────────────────────────┐              │
│  │  api-blue (active)   ←── Service selector        │              │
│  │  api-green (standby) ←── previous image tag      │              │
│  └──────────────────────────────────────────────────┘              │
│                                                                     │
│  Observability: kube-prometheus-stack + Loki + Promtail + Tempo     │
│  Backup:        MinIO + Velero (S3-compatible)                      │
│  Secrets:       Sealed Secrets (RSA-encrypted, safe in Git)         │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                          CI/CD PIPELINE                             │
│                                                                     │
│  PR opened → ci-validate.yml                                        │
│    ├── hadolint (Dockerfile linting)                                │
│    ├── kube-linter (K8s manifest validation)                        │
│    ├── gitleaks (secret scanning)                                   │
│    └── terraform validate (staging + prod)                          │
│                                                                     │
│  Merge to main → ci-build-publish.yml                               │
│    └── Docker build + push to GHCR                                  │
│         └── cd-update-tags.yml                                      │
│              └── Updates image tag in k8s/apps/overlays/            │
│                   └── ArgoCD auto-syncs → rolling deploy            │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                         TERRAFORM (IaC)                             │
│                                                                     │
│  modules/                                                           │
│  ├── backup-storage  → S3 bucket + Secrets Manager (shared)        │
│  ├── iam-user        → IAM User + Access Key (staging/LocalStack)   │
│  └── iam-irsa        → IAM Role OIDC trust policy (prod/EKS)        │
│                                                                     │
│  environments/staging  → LocalStack (localhost:4566)                │
│  environments/prod     → Real AWS + S3 remote backend               │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| Application | OpenPanel (Next.js, Fastify, BullMQ, Prisma, tRPC) |
| Databases | PostgreSQL 14, Redis 7.2, ClickHouse 25 |
| Container runtime | Docker Engine 24+, Docker Compose v2.20+ |
| Kubernetes | Minikube (local) / EKS (prod), Kustomize overlays |
| GitOps | ArgoCD — App of Apps pattern |
| CI/CD | GitHub Actions (3 workflows) |
| Observability | Prometheus, Grafana, Loki, Promtail, Tempo |
| Secrets | Sealed Secrets (Bitnami) |
| Backup | MinIO + Velero |
| IaC | Terraform — LocalStack (staging) / AWS (prod) |
| Security | Gitleaks, Hadolint, KubeLinter |

---

## Repository Structure

```
Project-DevOps/
├── .github/
│   ├── workflows/          # ci-validate, ci-build-publish, cd-update-tags
│   └── dependabot.yml      # Automated dependency updates (npm + Docker + Actions)
├── docker/
│   ├── prometheus/         # prometheus.yml + alerts.yml
│   ├── loki/               # loki-config.yaml (72h retention)
│   ├── promtail/           # promtail-config.yaml (Docker SD)
│   └── grafana/provisioning/datasources/
├── docker-compose.yml      # Full local stack (11 services)
├── .env.example            # All required environment variables
├── k8s/
│   ├── apps/
│   │   ├── base/openpanel/ # K8s manifests (databases, deployments, services, ingress)
│   │   └── overlays/staging|prod/
│   └── infrastructure/
│       ├── base/
│       │   ├── namespaces/
│       │   ├── argocd/     # install/ + applications/ + projects/
│       │   ├── observability/
│       │   ├── backup/
│       │   └── sealed-secrets/
│       └── overlays/staging|prod/
├── scripts/
│   ├── setup-minikube.sh
│   ├── install-argocd.sh
│   ├── blue-green-switch.sh
│   └── backup-restore.sh
├── terraform/
│   ├── modules/backup-storage/ iam-user/ iam-irsa/
│   └── environments/staging/ prod/
├── openpanel/              # Application source (pnpm monorepo)
├── Makefile
└── docs/documentacion/     # Architecture, Setup, GitOps, CI/CD, Observability docs
```

---

## Deployment Workflow

Full setup sequence from a fresh machine to a running cluster:

| Step | Command | What it does |
|------|---------|-------------|
| 1 | `make dev-up` | Docker Compose — app + monitoring stack |
| 2 | `make terraform-infra` | LocalStack: S3 bucket, IAM credentials for Velero, Secrets Manager slot |
| 3 | `make minikube-up` | 3-node K8s cluster + namespaces + DNS |
| 4 | `make argocd` | ArgoCD install + bootstrap App of Apps (GitOps takes over) |
| 5 | `make sealed-secrets` | Sealed Secrets controller + encrypt all credentials |
| 6 | `make velero-install` | Velero operator via Helm — reads credentials generated by step 2 |
| 7 | `make backup` | Deploy MinIO into the cluster + apply Velero backup schedules |

Operational commands (run anytime after setup):

| Command | What it does |
|---------|-------------|
| `make backup-run` | Trigger a manual Velero backup |
| `make blue-green` | Run the blue-green API switch |

---

## Local Setup

### Prerequisites

- Docker Engine 24+
- Docker Compose v2.20+
- `jq` (for verification commands)

### 1. Clone and configure environment

```bash
git clone <repo-url>
cd Project-DevOps

cp .env.example .env
# Edit .env — all required variables are documented inside
```

### 2. Start the full stack

```bash
docker compose up --build -d
```

First build downloads Node, compiles TypeScript — takes ~10 minutes. Subsequent builds use Docker layer cache (~1-2 min).

Watch startup progress:

```bash
docker compose ps
docker compose logs -f migrate   # Wait for "migrations deployed successfully"
```

### 3. Run ClickHouse migrations

OpenPanel uses **two separate database schemas** that require two separate migration steps:

- **PostgreSQL** — managed by Prisma. The `migrate` service in docker-compose runs `prisma migrate deploy` automatically on startup and exits. No action needed.
- **ClickHouse** — managed by a custom TypeScript migration script (`code-migrations/migrate.ts`). This is **not** triggered automatically because ClickHouse is only used for analytics writes — it is safe to run it once manually after the stack is up.

ClickHouse stores the analytics data: events, sessions, user profiles, and materialized views for fast aggregation. Without this step, the API will start but tracking events will fail silently because the target tables do not exist.

```bash
docker compose exec api sh -c \
  "cd /app/packages/db && node_modules/.bin/jiti ./code-migrations/migrate.ts --self-hosting"
```

You should see output confirming each table was created (`events`, `sessions`, `profiles`, materialized views, etc.). This command is idempotent — safe to run multiple times.

### 4. Verify everything is up

```bash
# All services healthy
docker compose ps

# API
curl http://localhost:3333/healthcheck

# Prometheus targets (all should be "up")
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Loki receiving logs
curl -s http://localhost:3100/loki/api/v1/label/service/values | jq
```

### 5. Create your first account

The dashboard registration form (`localhost:3000/onboarding`) has a known mismatch with the API schema — the form sends a single `name` field but the API requires `firstName`, `lastName`, and `confirmPassword` separately. Register directly via the API instead:

```bash
curl -s -X POST http://localhost:3333/trpc/auth.signUpEmail \
  -H "Content-Type: application/json" \
  -d '{
    "json": {
      "firstName": "Admin",
      "lastName": "User",
      "email": "admin@example.com",
      "password": "password123",
      "confirmPassword": "password123"
    }
  }' | jq
```

A successful response returns a session object with a `userId`. You can then log in normally at `http://localhost:3000`.

### 6. Access services

| Service | URL | Credentials |
|---|---|---|
| Dashboard | http://localhost:3000 | Use account created above |
| API | http://localhost:3333 | — |
| BullBoard (queues) | http://localhost:3334 | — |
| ClickHouse HTTP | http://localhost:8123 | default / see .env |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3001 | admin / admin |
| Loki | http://localhost:3100 | — |

### 7. Teardown

```bash
# Stop (keeps data volumes)
docker compose down

# Full wipe (removes all data)
docker compose down -v
```

---

## Data Flow

```
Browser / SDK
     │
     ▼ POST /track
   API (Fastify)
     │
     ▼ BullMQ enqueue
   Redis (queue buffer — noeviction)
     │
     ▼ BullMQ consume (batch: 5000 events / 10s)
   Worker
     │
     ▼ INSERT batch
   ClickHouse (events, sessions, profiles, materialized views)
     │
     ▼ SELECT analytics
   API → Dashboard (Next.js)

Sessions / Auth / Project config → PostgreSQL (31 tables via Prisma)
```

---

## Kubernetes Setup (Local)

### Prerequisites

- Minikube
- kubectl
- Helm 3
- kubeseal

### 1. Start the cluster

```bash
chmod +x scripts/setup-minikube.sh
./scripts/setup-minikube.sh
```

Creates a 3-node Minikube cluster with:
- Node labels: `workload=app` (m02), `workload=observability` (m03)
- 7 namespaces: openpanel, monitoring, logging, argocd, velero, sealed-secrets, storage
- Increased inotify limits for file watchers

### 2. Install ArgoCD

```bash
chmod +x scripts/install-argocd.sh
./scripts/install-argocd.sh
```

### 3. Bootstrap GitOps

Apply the bootstrap App of Apps:

```bash
kubectl apply -f k8s/infrastructure/overlays/staging/argocd/bootstrap-app.yaml
```

ArgoCD then syncs all components in order:
1. Namespaces
2. Sealed Secrets controller
3. local-path-provisioner (StorageClass)
4. kube-prometheus-stack
5. Loki + Promtail + Tempo
6. Velero + MinIO
7. OpenPanel application

### 4. Blue-Green deployment

```bash
# Switch traffic from blue to green
./scripts/blue-green-switch.sh green

# Roll back instantly
./scripts/blue-green-switch.sh blue
```

---

## Observability

### Local (Docker Compose)

| Tool | Purpose | URL |
|---|---|---|
| Prometheus | Metrics scraping — api:3000/metrics + worker:3000/metrics | http://localhost:9090 |
| Loki | Log aggregation — all containers via Promtail | http://localhost:3100 |
| Promtail | Log collector — reads Docker socket, ships to Loki | no external port |
| Grafana | Dashboards — Prometheus + Loki pre-provisioned | http://localhost:3001 |

> **Note:** Tempo (distributed tracing) is intentionally excluded from Docker Compose. Distributed tracing only provides value when services run on separate nodes — exactly the Kubernetes scenario. Tempo is added to the stack in `k8s/infrastructure/base/observability/`.

### Kubernetes

Full kube-prometheus-stack with:
- Prometheus (30d retention in prod, 3d in staging)
- Grafana with Prometheus + Loki + Tempo datasources
- AlertManager
- Node Exporter + kube-state-metrics
- ServiceMonitors for api, worker, postgres-exporter, redis-exporter, clickhouse

---

## Infrastructure (Terraform)

### Staging — LocalStack

```bash
cd terraform/environments/staging
docker run -d -p 4566:4566 localstack/localstack:3
terraform init
terraform plan
terraform apply
```

Creates: S3 bucket (versioned + encrypted), Secrets Manager slot, IAM user + access key.

### Production — AWS

```bash
cd terraform/environments/prod
terraform init   # Remote S3 backend + DynamoDB locking
terraform plan
terraform apply
```

Uses IRSA (IAM Roles for Service Accounts) — no static credentials in prod.

---

## CI/CD Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `ci-validate.yml` | PR opened/updated | Hadolint, KubeLinter, Gitleaks, terraform validate |
| `ci-build-publish.yml` | Merge to main | Docker build + push to GHCR |
| `cd-update-tags.yml` | After build | Updates image tag in k8s overlays → ArgoCD auto-syncs |

---

## Security

- **Secrets in Git**: All secrets are encrypted with Sealed Secrets (RSA, cluster-scoped key). Only the controller inside the cluster can decrypt them.
- **No static credentials in prod**: EKS uses IRSA (OIDC token exchange) — no IAM access keys.
- **Network Policies**: Default deny-all in `openpanel` namespace. Explicit allow rules per service pair.
- **Secret scanning**: Gitleaks runs on every PR — blocks commits containing credentials.
- **Image linting**: Hadolint enforces Dockerfile best practices.
- **Manifest validation**: KubeLinter checks K8s manifests against security policies.

---

## Documentation

Full documentation in [`docs/documentacion/`](docs/documentacion/):

- Architecture overview
- Local setup guide
- GitOps workflow
- CI/CD pipeline
- Blue-Green deployment
- Observability stack
- Backup and restore
- Terraform IaC
- Verification reports

---

## Source Code Patches

The OpenPanel source code under `openpanel/` is used as-is from upstream, with the following patches applied to make it work correctly in a local Docker Compose environment where the dashboard and API run on different hostnames.

### Dashboard auth cookie fix (`openpanel/apps/start/src/`)

**Problem**: After sign-in, the dashboard showed "Not authenticated" on every protected route.

**Root cause**: The dashboard needs to reach the API via two different URLs depending on who is making the call:
- **SSR (server-side rendering inside Docker)** — must use `http://host.docker.internal:3333` so the container can reach the API over Docker's internal network.
- **Browser (client-side React)** — must use `http://localhost:3333` so the `session` cookie set by the API is stored under the `localhost` domain.

The cookie mismatch caused the session to be invisible to SSR: the browser stored the cookie for `host.docker.internal`, but forwarded only `localhost` cookies when requesting `localhost:3000` (the dashboard), so the SSR layer never received a valid session.

**Files changed**:

| File | Change |
|---|---|
| `server/get-envs.ts` | Added `clientApiUrl` field — always `NEXT_PUBLIC_API_URL` (`localhost:3333`) regardless of `API_URL` |
| `router.tsx` | Pass both `apiUrl` and `clientApiUrl` to `getContext`; pass `clientApiUrl` to `Provider` |
| `integrations/tanstack-query/root-provider.tsx` | `getContext` now picks the URL based on environment: `host.docker.internal:3333` server-side, `localhost:3333` client-side (`typeof window === 'undefined'`) |
| `routes/__root.tsx` | Added `clientApiUrl` to `MyRouterContext` TypeScript interface |

**How it works after the fix**:
```
Browser sign-in  →  POST localhost:3333  →  Set-Cookie: session=xxx (domain=localhost)
Browser navigates to localhost:3000  →  sends Cookie: session=xxx
Dashboard SSR receives cookie  →  forwards to host.docker.internal:3333
API validates session  →  authenticated ✓
Browser context.trpc calls  →  localhost:3333  →  cookie sent ✓
```

---

## License

MIT
