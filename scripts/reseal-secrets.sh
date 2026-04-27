#!/bin/bash
set -euo pipefail

# =============================================================================
# reseal-secrets.sh — re-seal the six SealedSecrets from local plaintext
#
# Background:
#   Every `cluster-up` regenerates the sealed-secrets controller's keypair,
#   which orphans every SealedSecret committed against the previous public
#   key. Grafana, MinIO and all openpanel pods CrashLoop until the six
#   SealedSecrets are re-sealed against the new public key.
#
# What this script does:
#   1. Waits for the sealed-secrets controller deployment to become Ready.
#   2. Fetches the live public certificate (kubeseal --fetch-cert).
#   3. Reads plaintext from the repo-root .env (plus a handful of
#      sensible defaults for values that aren't in .env — Grafana admin
#      credentials, MinIO root credentials).
#   4. Builds six plaintext Secret manifests with `kubectl create secret …
#      --dry-run=client`, pipes each through kubeseal, writes to /tmp/sealed/.
#   5. Applies the six SealedSecrets to the cluster — the controller
#      decrypts them and materialises the real Secret objects within a
#      few seconds, unblocking any pods that were Pending on a missing
#      secret.
#
# Usage:
#   ./scripts/reseal-secrets.sh
#
# Environment overrides (all optional):
#   ENV_FILE                 path to the .env file          (default: .env)
#   GIT_SECRETS_FILE         path to the committed YAML     (default:
#                              k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml)
#   SKIP_GIT_REWRITE         set to 1 to skip the file rewrite (live-apply only)
#   GRAFANA_ADMIN_USER       grafana admin user             (default: admin)
#   GRAFANA_ADMIN_PASSWORD   grafana admin password         (default: admin)
#   MINIO_ROOT_USER          minio root user                (default: minioadmin)
#   MINIO_ROOT_PASSWORD      minio root password            (default: minioadmin)
# =============================================================================

ENV_FILE="${ENV_FILE:-.env}"
WORK_DIR="${WORK_DIR:-/tmp/sealed}"
PUBKEY="${WORK_DIR}/pubkey.pem"
CONTROLLER_NS="sealed-secrets"
CONTROLLER_NAME="sealed-secrets"
GIT_SECRETS_FILE="${GIT_SECRETS_FILE:-k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml}"
SKIP_GIT_REWRITE="${SKIP_GIT_REWRITE:-0}"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header()  { echo -e "\n${CYAN}${BOLD}=== $* ===${RESET}"; }
step()    { echo -e "${YELLOW}--- $* ---${RESET}"; }
success() { echo -e "${GREEN}${BOLD}✔ $*${RESET}"; }
error()   { echo -e "${RED}${BOLD}✖ ERROR: $*${RESET}" >&2; }
info()    { echo -e "  $*"; }

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------
header "Checking prerequisites"

for cmd in kubectl kubeseal; do
  if ! command -v "${cmd}" &>/dev/null; then
    error "'${cmd}' is not installed or not in PATH"
    if [ "${cmd}" = "kubeseal" ]; then
      info "Install: https://github.com/bitnami-labs/sealed-secrets/releases"
    fi
    exit 1
  fi
  success "${cmd} found"
done

if [ ! -f "${ENV_FILE}" ]; then
  error ".env file not found at: ${ENV_FILE}"
  info  "Run 'make bootstrap' first (creates .env from .env.example)."
  exit 1
fi
success ".env file found at ${ENV_FILE}"

# -----------------------------------------------------------------------------
# Load .env — every non-comment KEY=VALUE line becomes an exported variable
# -----------------------------------------------------------------------------
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# Required plaintext values — fail fast if any are missing
for var in POSTGRES_USER POSTGRES_PASSWORD CLICKHOUSE_PASSWORD CLICKHOUSE_URL \
           REDIS_URL DATABASE_URL DATABASE_URL_DIRECT API_SECRET; do
  if [ -z "${!var:-}" ]; then
    error "${var} is missing or empty in ${ENV_FILE}"
    exit 1
  fi
done

# Derive values not stored directly in .env.
# REDIS_URL has several common forms:
#   redis://host:6379                    (no auth)
#   redis://:password@host:6379          (password, no user)
#   redis://user:password@host:6379      (user + password)
# Only the middle two forms yield a password. When there isn't one we
# default REDIS_PASSWORD to empty — Redis reads `--requirepass ""` as
# "auth disabled", so pods connect without credentials and the local
# stack still works.
REDIS_PASSWORD="${REDIS_PASSWORD:-$(echo "${REDIS_URL}" | sed -nE 's|^redis://[^:@/]*:([^@]+)@.*|\1|p')}"
if [ -z "${REDIS_PASSWORD}" ]; then
  echo -e "${YELLOW}  (note) REDIS_URL has no password — sealing REDIS_PASSWORD as empty string (Redis auth disabled)${RESET}"
fi

# CLICKHOUSE_URL format: http[s]://user:password@host:8123/db
CLICKHOUSE_USER=$(echo "${CLICKHOUSE_URL}" | sed -nE 's|^https?://([^:/@]+):.*|\1|p')
if [ -z "${CLICKHOUSE_USER}" ]; then
  error "Could not parse CLICKHOUSE_USER from CLICKHOUSE_URL='${CLICKHOUSE_URL}'"
  info  "Expected format: http://user:password@clickhouse:8123/db"
  exit 1
fi

# Defaults for keys not in .env (all overridable via env var)
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"

# -----------------------------------------------------------------------------
# Wait for the sealed-secrets controller to be Ready
# -----------------------------------------------------------------------------
header "Waiting for sealed-secrets controller"

step "Ensuring namespace '${CONTROLLER_NS}' exists"
if ! kubectl get ns "${CONTROLLER_NS}" &>/dev/null; then
  error "Namespace '${CONTROLLER_NS}' not found — is ArgoCD still syncing?"
  info  "Run: kubectl get applications -n argocd -w"
  exit 1
fi
success "Namespace '${CONTROLLER_NS}' is present"

step "Waiting for deployment '${CONTROLLER_NAME}' to become Available (up to 5m)"
kubectl -n "${CONTROLLER_NS}" rollout status \
  "deployment/${CONTROLLER_NAME}" --timeout=300s
success "Controller is Ready"

# -----------------------------------------------------------------------------
# Fetch the live public certificate
# -----------------------------------------------------------------------------
header "Fetching the controller's public certificate"

mkdir -p "${WORK_DIR}"
kubeseal \
  --controller-namespace "${CONTROLLER_NS}" \
  --controller-name      "${CONTROLLER_NAME}" \
  --fetch-cert > "${PUBKEY}"
success "Wrote public cert to ${PUBKEY}"

# -----------------------------------------------------------------------------
# Seal each secret
# -----------------------------------------------------------------------------
header "Sealing six secrets"

seal_secret() {
  local name="$1" namespace="$2" outfile="$3"
  shift 3
  step "Sealing ${name} (ns=${namespace})"
  kubectl create secret generic "${name}" \
    --namespace="${namespace}" \
    "$@" \
    --dry-run=client -o yaml \
    | kubeseal --cert "${PUBKEY}" --format yaml \
    > "${outfile}"
  success "Wrote ${outfile}"
}

seal_secret postgres-credentials openpanel \
  "${WORK_DIR}/postgres-credentials.sealed.yaml" \
  "--from-literal=POSTGRES_USER=${POSTGRES_USER}" \
  "--from-literal=POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"

seal_secret redis-credentials openpanel \
  "${WORK_DIR}/redis-credentials.sealed.yaml" \
  "--from-literal=REDIS_PASSWORD=${REDIS_PASSWORD}"

seal_secret clickhouse-credentials openpanel \
  "${WORK_DIR}/clickhouse-credentials.sealed.yaml" \
  "--from-literal=CLICKHOUSE_USER=${CLICKHOUSE_USER}" \
  "--from-literal=CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD}"

seal_secret openpanel-secrets openpanel \
  "${WORK_DIR}/openpanel-secrets.sealed.yaml" \
  "--from-literal=API_SECRET=${API_SECRET}" \
  "--from-literal=DATABASE_URL=${DATABASE_URL}" \
  "--from-literal=DATABASE_URL_DIRECT=${DATABASE_URL_DIRECT}" \
  "--from-literal=CLICKHOUSE_URL=${CLICKHOUSE_URL}" \
  "--from-literal=REDIS_URL=${REDIS_URL}"

seal_secret grafana-admin-credentials observability \
  "${WORK_DIR}/grafana-admin-credentials.sealed.yaml" \
  "--from-literal=admin-user=${GRAFANA_ADMIN_USER}" \
  "--from-literal=admin-password=${GRAFANA_ADMIN_PASSWORD}"

seal_secret minio-credentials backup \
  "${WORK_DIR}/minio-credentials.sealed.yaml" \
  "--from-literal=MINIO_ROOT_USER=${MINIO_ROOT_USER}" \
  "--from-literal=MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}"

# -----------------------------------------------------------------------------
# Apply all six at once
# -----------------------------------------------------------------------------
header "Applying the six SealedSecrets to the cluster"

# shellcheck disable=SC2012
ls "${WORK_DIR}"/*.sealed.yaml
echo ""
cat "${WORK_DIR}"/*.sealed.yaml | kubectl apply -f -

success "SealedSecrets applied — the controller is decrypting now"

# -----------------------------------------------------------------------------
# Verify: poll each target Secret for up to 60 seconds
# -----------------------------------------------------------------------------
header "Verifying real Secrets were materialized"

check_secret() {
  local namespace="$1" name="$2"
  for i in $(seq 1 12); do
    if kubectl get secret -n "${namespace}" "${name}" &>/dev/null; then
      success "${namespace}/${name}"
      return 0
    fi
    sleep 5
  done
  error "${namespace}/${name} did not appear after 60s — check 'kubectl logs -n ${CONTROLLER_NS} deploy/${CONTROLLER_NAME}'"
  return 1
}

check_secret openpanel     postgres-credentials
check_secret openpanel     redis-credentials
check_secret openpanel     clickhouse-credentials
check_secret openpanel     openpanel-secrets
check_secret observability grafana-admin-credentials
check_secret backup        minio-credentials

# -----------------------------------------------------------------------------
# Rewrite the committed git file so ArgoCD selfHeal stops reverting us.
# -----------------------------------------------------------------------------
if [ "${SKIP_GIT_REWRITE}" = "1" ]; then
  echo ""
  info "SKIP_GIT_REWRITE=1 — leaving ${GIT_SECRETS_FILE} untouched"
  info "ArgoCD selfHeal will revert live SealedSecrets to git state; expect Degraded."
else
  header "Rewriting ${GIT_SECRETS_FILE}"

  if [ ! -f "${GIT_SECRETS_FILE}" ]; then
    error "${GIT_SECRETS_FILE} not found — refusing to create a new file from scratch"
    info  "Set GIT_SECRETS_FILE=<path> or SKIP_GIT_REWRITE=1 to bypass"
    exit 1
  fi

  strip_leading_sep() {
    awk 'NR==1 && /^---[[:space:]]*$/ {next} {print}' "$1"
  }

  tmp_out="$(mktemp)"
  {
    cat <<'EOF'
# =============================================================================
# Sealed Secrets — All cluster credentials
#
# Sections:
#   1. postgres-credentials        (namespace: openpanel)
#   2. redis-credentials           (namespace: openpanel)
#   3. clickhouse-credentials      (namespace: openpanel)
#   4. openpanel-secrets           (namespace: openpanel)
#   5. grafana-admin-credentials   (namespace: observability)
#   6. minio-credentials           (namespace: backup)
#
# Regenerated by scripts/reseal-secrets.sh. Do not hand-edit — rerun the
# script, then commit the diff.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. PostgreSQL credentials
#    Used by: postgres StatefulSet, openpanel-secrets (DATABASE_URL)
# -----------------------------------------------------------------------------
---
EOF
    strip_leading_sep "${WORK_DIR}/postgres-credentials.sealed.yaml"

    cat <<'EOF'

# -----------------------------------------------------------------------------
# 2. Redis credentials
#    Used by: redis Deployment, openpanel-secrets (REDIS_URL)
# -----------------------------------------------------------------------------
---
EOF
    strip_leading_sep "${WORK_DIR}/redis-credentials.sealed.yaml"

    cat <<'EOF'

# -----------------------------------------------------------------------------
# 3. ClickHouse credentials
#    Used by: clickhouse StatefulSet, openpanel-secrets (CLICKHOUSE_URL)
# -----------------------------------------------------------------------------
---
EOF
    strip_leading_sep "${WORK_DIR}/clickhouse-credentials.sealed.yaml"

    cat <<'EOF'

# -----------------------------------------------------------------------------
# 4. OpenPanel application secrets
#    Used by: api and worker Deployments (envFrom)
# -----------------------------------------------------------------------------
---
EOF
    strip_leading_sep "${WORK_DIR}/openpanel-secrets.sealed.yaml"

    cat <<'EOF'

# -----------------------------------------------------------------------------
# 5. Grafana admin credentials
#    Used by: kube-prometheus-stack (grafana.admin.existingSecret)
# -----------------------------------------------------------------------------
---
EOF
    strip_leading_sep "${WORK_DIR}/grafana-admin-credentials.sealed.yaml"

    cat <<'EOF'

# -----------------------------------------------------------------------------
# 6. MinIO credentials
#    Used by: minio Deployment (MINIO_ROOT_USER / MINIO_ROOT_PASSWORD)
# -----------------------------------------------------------------------------
---
EOF
    strip_leading_sep "${WORK_DIR}/minio-credentials.sealed.yaml"
  } > "${tmp_out}"

  mv "${tmp_out}" "${GIT_SECRETS_FILE}"
  success "Rewrote ${GIT_SECRETS_FILE}"
fi

echo ""
echo -e "${GREEN}${BOLD}=== Re-seal complete ===${RESET}"
echo ""
info "Pods that were Pending on a missing Secret will now recover"
info "without a restart — the kubelet retries the mount automatically."
info "Monitor progress: ${BOLD}kubectl get pods -A -w${RESET}"
if [ "${SKIP_GIT_REWRITE}" != "1" ]; then
  echo ""
  info "${BOLD}Next step${RESET}: commit + push ${GIT_SECRETS_FILE} so ArgoCD"
  info "stops reverting the live SealedSecrets to the stale git copies:"
  info "  ${BOLD}git add ${GIT_SECRETS_FILE} && git commit -m 'chore: re-seal secrets' && git push${RESET}"
fi
echo ""
