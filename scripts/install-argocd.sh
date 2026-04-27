#!/bin/bash
set -euo pipefail

# =============================================================================
# Install ArgoCD via Kustomize + Helm and bootstrap the App of Apps
#
# Usage:
#   ./scripts/install-argocd.sh [ENV]
#   ENV defaults to "staging"
#
# What it does:
#   1. Validates prerequisites (kustomize, kubectl)
#   2. Installs ArgoCD by rendering the env overlay with kustomize + Helm
#   3. Waits for the admin secret to be available
#   4. Applies the AppProject (defines RBAC scope)
#   5. Applies the bootstrap Application (App of Apps — manages all other apps)
#
# Overlay rendered:
#   k8s/infrastructure/overlays/<ENV>/argocd/kustomization.yaml
# =============================================================================

ENV="${1:-staging}"
NAMESPACE="argocd"
OVERLAY="k8s/infrastructure/overlays/${ENV}/argocd"
BOOTSTRAP_APP="${OVERLAY}/bootstrap-app.yaml"

KUSTOMIZE_VERSION="5.4.3"
KUSTOMIZE_MIN_MAJOR=4
KUSTOMIZE_MIN_MINOR=1

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
check_prerequisites() {
  local missing=0

  header "Checking prerequisites (ENV=${ENV})"

  # Auto-install kustomize if missing
  if ! command -v kustomize &>/dev/null; then
    info "kustomize not found — installing v${KUSTOMIZE_VERSION} to ~/.local/bin..."
    mkdir -p "${HOME}/.local/bin"
    KZ_TGZ="kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"
    curl -fsSL \
      "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/${KZ_TGZ}" \
      -o "/tmp/${KZ_TGZ}"
    tar -xzf "/tmp/${KZ_TGZ}" -C "${HOME}/.local/bin"
    rm -f "/tmp/${KZ_TGZ}"
    export PATH="${HOME}/.local/bin:${PATH}"
    success "kustomize v${KUSTOMIZE_VERSION} installed to ~/.local/bin"
  else
    success "kustomize found"
  fi

  if ! command -v kubectl &>/dev/null; then
    error "'kubectl' is not installed or not in PATH"
    missing=1
  else
    success "kubectl found"
  fi

  if [ "${missing}" -eq 1 ]; then
    error "Install missing tools and re-run this script."
    exit 1
  fi

  # Kustomize minimum version (requires >= KUSTOMIZE_MIN_MAJOR.KUSTOMIZE_MIN_MINOR)
  step "Checking kustomize version (minimum v${KUSTOMIZE_MIN_MAJOR}.${KUSTOMIZE_MIN_MINOR})"
  KUSTOMIZE_RAW=$(kustomize version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  KUSTOMIZE_MAJOR=$(echo "${KUSTOMIZE_RAW}" | cut -d. -f1 | tr -d 'v')
  KUSTOMIZE_MINOR=$(echo "${KUSTOMIZE_RAW}" | cut -d. -f2)

  if [ -z "${KUSTOMIZE_MAJOR}" ]; then
    error "Could not determine kustomize version."
    exit 1
  fi

  if [ "${KUSTOMIZE_MAJOR}" -lt "${KUSTOMIZE_MIN_MAJOR}" ] || \
     { [ "${KUSTOMIZE_MAJOR}" -eq "${KUSTOMIZE_MIN_MAJOR}" ] && \
       [ "${KUSTOMIZE_MINOR}" -lt "${KUSTOMIZE_MIN_MINOR}" ]; }; then
    error "kustomize v${KUSTOMIZE_MIN_MAJOR}.${KUSTOMIZE_MIN_MINOR}+ required. Found: ${KUSTOMIZE_RAW}"
    exit 1
  fi
  success "kustomize ${KUSTOMIZE_RAW} — OK"

  if [ ! -d "${OVERLAY}" ]; then
    error "Overlay not found: ${OVERLAY}"
    info  "Available environments: $(ls k8s/infrastructure/overlays/)"
    exit 1
  fi
  success "Overlay found: ${OVERLAY}"
}

# Wait for a Kubernetes secret to exist
wait_for_secret() {
  local namespace="${1}"
  local secret="${2}"
  local max_attempts=30
  local attempt=0

  step "Waiting for secret '${secret}' in namespace '${namespace}'..."
  until kubectl -n "${namespace}" get secret "${secret}" &>/dev/null; do
    attempt=$((attempt + 1))
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      error "Secret '${secret}' not found after ${max_attempts} attempts."
      exit 1
    fi
    info "Attempt ${attempt}/${max_attempts} — retrying in 5s..."
    sleep 5
  done
  success "Secret '${secret}' is available"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
check_prerequisites

header "Installing ArgoCD (ENV=${ENV}) — pass 1: chart only"
step "Rendering base chart (registers CRDs — no Application/AppProject resources yet)"
# Pass 1: install only the ArgoCD Helm chart from the base.
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone \
  k8s/infrastructure/base/argocd/install \
  | kubectl apply -f -
success "ArgoCD chart applied"

header "Waiting for ArgoCD CRDs to be established"
for crd in applications.argoproj.io appprojects.argoproj.io applicationsets.argoproj.io; do
  step "Waiting for CRD: ${crd}"
  kubectl wait --for=condition=Established "crd/${crd}" --timeout=60s
done
success "ArgoCD CRDs established"

header "Waiting for ArgoCD to be ready"
kubectl rollout status deployment/argocd-server -n "${NAMESPACE}" --timeout=5m
success "ArgoCD server is ready"

header "Installing ArgoCD (ENV=${ENV}) — pass 2: full overlay"
step "Rendering overlay: ${OVERLAY}"
# Pass 2: apply the full overlay — CRDs now registered, so Application and
kustomize build --enable-helm --load-restrictor LoadRestrictionsNone "${OVERLAY}" \
  | kubectl apply -f -
success "ArgoCD overlay applied (Applications + AppProject)"

header "Retrieving initial admin password"
wait_for_secret "${NAMESPACE}" "argocd-initial-admin-secret"
ARGOCD_PASSWORD=$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)
echo ""
info "  ${BOLD}Username:${RESET} admin"
info "  ${BOLD}Password:${RESET} ${ARGOCD_PASSWORD}"

header "Bootstrapping App of Apps (${ENV})"
# One-time trigger: registers the root ArgoCD Application into the cluster.
# After this, ArgoCD watches k8s/infrastructure/overlays/${ENV}/argocd and
# manages all other Application CRs automatically via GitOps.
kubectl apply -f "${BOOTSTRAP_APP}"
success "Bootstrap Application applied"

echo ""
echo -e "${GREEN}${BOLD}=== ArgoCD installed and bootstrapped (${ENV}) ===${RESET}"
echo ""
info "  Access:   ${BOLD}http://argocd.local${RESET}"
info "  Username: ${BOLD}admin${RESET}"
info "  Password: ${BOLD}${ARGOCD_PASSWORD}${RESET}"
echo ""
