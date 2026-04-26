#!/bin/bash
# =============================================================================
# ensure-sealing-key.sh — make sure a sealed-secrets keypair exists in cluster
#
# Two paths, picked automatically:
#
#   1. Backup exists at ~/.config/openpanel/sealing-key.yaml
#      → apply it to the cluster. This is the repeat-bring-up case — the
#        script has run here before and we're just putting the same key
#        back.
#
#   2. No backup
#      → generate a fresh RSA-4096 keypair locally with openssl, install
#        it as a Kubernetes Secret with the label the controller looks
#        for, and save a copy to ~/.config/openpanel/sealing-key.yaml so
#        the next bring-up takes path 1. This is the thesis-reviewer
#        first-run case.
#
# Why bother:
#   By default the sealed-secrets controller generates a brand-new keypair
#   every time it's installed. That's a problem for GitOps — every
#   SealedSecret already committed to git was encrypted against the OLD
#   cluster's key, so the new cluster can't decrypt any of them. Pinning
#   the keypair before the controller starts makes cluster bring-ups
#   reproducible without shipping a private key in git.
#
# Idempotent — safe to run as many times as you like.
#
# Has to run between setup-minikube.sh (creates the namespace) and
# install-argocd.sh (spins up the controller via ArgoCD).
#
# Usage:
#   ./scripts/ensure-sealing-key.sh
# =============================================================================

set -euo pipefail

BACKUP_DIR="${HOME}/.config/openpanel"
BACKUP_FILE="${BACKUP_DIR}/sealing-key.yaml"
NAMESPACE="sealed-secrets"
SECRET_NAME="sealed-secrets-key-bootstrap"
CN="sealed-secret/O=sealed-secret"
KEY_DAYS=3650   # 10 years — this is a master key, not a TLS cert

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

# Make sure the namespace exists. setup-minikube.sh creates it earlier in the
# pipeline, but this script may be run standalone, so be defensive.
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# -----------------------------------------------------------------------------
# Path A — restore from existing backup
# -----------------------------------------------------------------------------
if [ -f "${BACKUP_FILE}" ]; then
  echo -e "${CYAN}${BOLD}▶  Restoring Sealed-Secrets keypair from backup${RESET}"
  echo -e "${YELLOW}   →  Source: ${BACKUP_FILE}${RESET}"

  kubectl apply -n "${NAMESPACE}" -f "${BACKUP_FILE}" >/dev/null

  KEY_NAME=$(kubectl -n "${NAMESPACE}" get secret \
    -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  echo -e "${GREEN}${BOLD}   ✔  Keypair restored as secret '${KEY_NAME}'${RESET}"
  echo "      The sealed-secrets controller will adopt this key on first start."
  exit 0
fi

# -----------------------------------------------------------------------------
# Path B — no backup, generate a fresh keypair locally
# -----------------------------------------------------------------------------
echo -e "${CYAN}${BOLD}▶  No keypair backup found — generating a fresh one${RESET}"
echo -e "${YELLOW}   →  This is the first time you've brought up the cluster on this machine.${RESET}"

if ! command -v openssl >/dev/null 2>&1; then
  echo -e "${RED}${BOLD}   ✖  openssl not installed. Install with: sudo apt install openssl${RESET}"
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

echo -e "${YELLOW}   →  Generating RSA-4096 keypair (10-year validity)${RESET}"
openssl req -x509 -nodes -newkey rsa:4096 \
  -keyout "${TMPDIR}/tls.key" \
  -out "${TMPDIR}/tls.crt" \
  -subj "/CN=${CN}" \
  -days "${KEY_DAYS}" \
  2>/dev/null

# Build a TLS Secret with the label the sealed-secrets controller looks for.
# When the controller starts it scans the namespace for any Secret labelled
# `sealedsecrets.bitnami.com/sealed-secrets-key=active` and uses the most
# recent one as its keypair (instead of generating a new one).
echo -e "${YELLOW}   →  Installing keypair into namespace '${NAMESPACE}'${RESET}"
kubectl create secret tls "${SECRET_NAME}" \
  --cert="${TMPDIR}/tls.crt" \
  --key="${TMPDIR}/tls.key" \
  -n "${NAMESPACE}" \
  --dry-run=client -o yaml \
  | sed '/^metadata:/a\  labels:\n    sealedsecrets.bitnami.com/sealed-secrets-key: active' \
  | kubectl apply -f - >/dev/null

# Persist a copy locally so future cluster-up bring-ups skip generation.
echo -e "${YELLOW}   →  Saving backup to ${BACKUP_FILE}${RESET}"
kubectl -n "${NAMESPACE}" get secret "${SECRET_NAME}" -o yaml \
  | sed -e '/resourceVersion:/d' \
        -e '/uid:/d' \
        -e '/creationTimestamp:/d' \
        -e '/^  selfLink:/d' \
  > "${BACKUP_FILE}"
chmod 600 "${BACKUP_FILE}"

echo ""
echo -e "${GREEN}${BOLD}   ✔  Fresh keypair generated, installed, and backed up${RESET}"
echo ""
echo "      What just happened:"
echo "         1. A 4096-bit RSA keypair was created on this machine."
echo "         2. It was applied as Secret/${SECRET_NAME} in namespace '${NAMESPACE}'."
echo "         3. A copy was saved to ${BACKUP_FILE} (chmod 600, NOT in git)."
echo ""
echo "      What this means going forward:"
echo "         - The sealed-secrets controller will adopt this keypair when it starts."
echo "         - Every future 'make cluster-up' on this machine will reuse the same"
echo "           keypair (no more 'no key could decrypt' errors)."
echo "         - The next step (stabilize-secrets.sh) will re-seal the 6 secrets in"
echo "           git against this keypair so they decrypt cleanly on this cluster."
echo ""
echo -e "      ${BOLD}Back up ${BACKUP_FILE} like an SSH private key.${RESET}"
echo "      Lose it and you cannot decrypt anything sealed with this key."
