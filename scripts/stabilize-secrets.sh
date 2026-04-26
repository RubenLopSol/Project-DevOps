#!/bin/bash
# =============================================================================
# stabilize-secrets.sh — final secrets pass after ArgoCD bootstrap
#
# This is the last step of `make cluster-up`. Three things to do:
#
#   1. Wait for the sealed-secrets controller to come up and for the 6
#      SealedSecret CRs from git to land in the cluster.
#
#   2. Check whether all 6 actually decrypt with this cluster's key.
#      If they do, we're done — exit quietly. This is the steady-state
#      case on a repeat bring-up, where ensure-sealing-key.sh put the
#      same key back that the SealedSecrets in git were sealed against.
#
#   3. If any of them can't decrypt — typical first-run for a reviewer
#      who just generated a fresh key — fix it automatically:
#         a. Turn off selfHeal on the `bootstrap` and `sealed-secrets`
#            apps so ArgoCD doesn't revert us back to git's stale
#            ciphertext.
#         b. Re-run reseal-secrets.sh to re-encrypt the .env values
#            against THIS cluster's key, then apply with kubectl.
#         c. Print clear next-steps for re-enabling selfHeal once you're
#            happy and ready to commit the regenerated secrets.yaml.
#
# Idempotent — safe to run as many times as you like.
#
# Usage:
#   ./scripts/stabilize-secrets.sh
# =============================================================================

set -euo pipefail

NAMESPACE="sealed-secrets"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

SEALED_SECRETS=(
  "openpanel/postgres-credentials"
  "openpanel/redis-credentials"
  "openpanel/clickhouse-credentials"
  "openpanel/openpanel-secrets"
  "observability/grafana-admin-credentials"
  "backup/minio-credentials"
)

echo -e "${CYAN}${BOLD}▶  Stabilising SealedSecrets${RESET}"

# -----------------------------------------------------------------------------
# 1. Wait for sealed-secrets controller
# -----------------------------------------------------------------------------
echo -e "${YELLOW}   →  Waiting for sealed-secrets controller to be Ready${RESET}"
attempts=0
until kubectl -n "${NAMESPACE}" get deployment sealed-secrets &>/dev/null; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo -e "${RED}${BOLD}   ✖  Controller deployment not found after 5 min — check ArgoCD sealed-secrets app${RESET}"
    exit 1
  fi
  sleep 5
done
kubectl -n "${NAMESPACE}" rollout status deployment/sealed-secrets --timeout=180s

# -----------------------------------------------------------------------------
# 2. Wait for the SealedSecret CRs to land in the cluster (ArgoCD wave 1 sync)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}   →  Waiting for the 6 SealedSecret resources to be applied by ArgoCD${RESET}"
attempts=0
until [ "$(kubectl get sealedsecret -A --no-headers 2>/dev/null | wc -l)" -ge 6 ]; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo -e "${YELLOW}   ⚠  Fewer than 6 SealedSecret CRs after 5 min.${RESET}"
    echo "      This usually means ArgoCD hasn't finished syncing the sealed-secrets"
    echo "      app yet — check 'kubectl get applications -n argocd'."
    echo "      Falling through to reseal-from-.env to bootstrap them locally."
    break
  fi
  sleep 5
done

# Give the controller a moment to attempt decryption of whatever's there now.
sleep 8

# -----------------------------------------------------------------------------
# 3. Check decryption health
# -----------------------------------------------------------------------------
echo -e "${YELLOW}   →  Checking if all 6 SealedSecrets decrypt with the current cluster key${RESET}"

errors=0
missing=0
for ns_name in "${SEALED_SECRETS[@]}"; do
  ns="${ns_name%/*}"
  name="${ns_name#*/}"

  if ! kubectl -n "${ns}" get sealedsecret "${name}" >/dev/null 2>&1; then
    missing=$((missing + 1))
    echo -e "      ${YELLOW}⚠  ${ns_name}: not yet present in cluster${RESET}"
    continue
  fi

  msg=$(kubectl -n "${ns}" get sealedsecret "${name}" \
    -o jsonpath='{.status.conditions[-1].message}' 2>/dev/null || true)

  if [ -n "${msg}" ] && echo "${msg}" | grep -qi "no key could decrypt"; then
    errors=$((errors + 1))
    echo -e "      ${RED}✗  ${ns_name}: cannot decrypt with current key${RESET}"
  else
    echo -e "      ${GREEN}✓  ${ns_name}: decrypts cleanly${RESET}"
  fi
done

# -----------------------------------------------------------------------------
# 4. Steady-state path — nothing to do
# -----------------------------------------------------------------------------
if [ "${errors}" -eq 0 ] && [ "${missing}" -eq 0 ]; then
  echo ""
  echo -e "${GREEN}${BOLD}   ✔  All 6 SealedSecrets decrypt cleanly — no reseal needed.${RESET}"
  echo "      This means the cluster's keypair matches the one the SealedSecrets"
  echo "      in git were sealed against. Steady-state, all good."
  exit 0
fi

# -----------------------------------------------------------------------------
# 5. Repair path — reseal against the current cluster's key
# -----------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}${BOLD}   →  ${errors} of 6 SealedSecrets cannot decrypt (and ${missing} not yet visible).${RESET}"
echo "      This is expected on a first bring-up where ensure-sealing-key.sh"
echo "      generated a fresh key for this machine. Auto-resealing now."
echo ""

echo -e "${YELLOW}   →  Disabling selfHeal on bootstrap + sealed-secrets so ArgoCD does not revert${RESET}"
# Wait for the apps to exist (they may not yet on a brand-new install).
attempts=0
until kubectl -n argocd get application bootstrap >/dev/null 2>&1 && \
      kubectl -n argocd get application sealed-secrets >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 30 ]; then
    echo -e "${RED}${BOLD}   ✖  ArgoCD apps 'bootstrap' or 'sealed-secrets' missing after 2.5 min${RESET}"
    exit 1
  fi
  sleep 5
done

kubectl -n argocd patch application bootstrap --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":false}}}}' >/dev/null
kubectl -n argocd patch application sealed-secrets --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":false,"selfHeal":false}}}}' >/dev/null
echo -e "${GREEN}      ✓  selfHeal disabled on bootstrap + sealed-secrets${RESET}"

echo ""
echo -e "${YELLOW}   →  Running scripts/reseal-secrets.sh${RESET}"
bash scripts/reseal-secrets.sh

echo ""
echo -e "${GREEN}${BOLD}   ✔  Stabilisation complete${RESET}"
echo ""
echo "      State now:"
echo "         - All 6 underlying Secrets materialised in the right namespaces"
echo "         - SealedSecret CRs in cluster decrypt cleanly with this machine's key"
echo "         - Local k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml"
echo "           was rewritten with fresh ciphertext"
echo "         - ArgoCD selfHeal is OFF on bootstrap + sealed-secrets so this stays"
echo ""
echo "      Once you're happy with the cluster, you have two paths:"
echo ""
echo "      A) THESIS REVIEWER  — leave it as-is. Workloads run, demo works, no"
echo "         git operations needed. Stop here."
echo ""
echo "      B) THESIS AUTHOR    — commit the regenerated secrets.yaml so future"
echo "         clusters start clean and re-enable selfHeal:"
echo ""
echo "             git add k8s/infrastructure/overlays/staging/sealed-secrets/secrets.yaml"
echo "             git commit -m 'chore: re-seal secrets against current cluster key'"
echo "             git push"
echo "             kubectl -n argocd patch application bootstrap sealed-secrets \\"
echo "                 --type=merge \\"
echo "                 -p '{\"spec\":{\"syncPolicy\":{\"automated\":{\"selfHeal\":true}}}}'"
