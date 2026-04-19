#!/bin/bash
set -euo pipefail

# =============================================================================
# Blue-Green Deployment Switch for OpenPanel API
#
# Usage:
#   ./scripts/blue-green-switch.sh
#
# What it does:
#   1. Detects which version (blue/green) is currently active
#   2. Scales up the target (inactive) deployment
#   3. Waits for the target to be fully ready
#   4. Runs health checks on every target pod
#   5. Asks for confirmation before switching traffic
#   6. Patches the service selector to the target version
#   7. Optionally scales down the old deployment
# =============================================================================

NAMESPACE="openpanel"
SERVICE="openpanel-api"

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
if ! command -v kubectl &>/dev/null; then
  error "kubectl is not installed or not in PATH"
  exit 1
fi

# -----------------------------------------------------------------------------
# Detect current active version
# -----------------------------------------------------------------------------
CURRENT=$(kubectl get svc "${SERVICE}" -n "${NAMESPACE}" \
  -o jsonpath='{.spec.selector.version}' 2>/dev/null || true)

if [ -z "${CURRENT}" ]; then
  error "Could not determine current active version from service '${SERVICE}'."
  info "Make sure the service selector has a 'version' key."
  exit 1
fi

if [ "${CURRENT}" = "blue" ]; then
  TARGET="green"
else
  TARGET="blue"
fi

TARGET_DEPLOYMENT="${SERVICE}-${TARGET}"

header "Blue-Green Switch"
info "  Current active: ${BOLD}${CURRENT}${RESET}"
info "  Target:         ${BOLD}${TARGET}${RESET}"

# -----------------------------------------------------------------------------
# Step 1: Verify target deployment exists
# -----------------------------------------------------------------------------
step "Step 1: Checking target deployment '${TARGET_DEPLOYMENT}'"
if ! kubectl get deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" &>/dev/null; then
  error "Target deployment '${TARGET_DEPLOYMENT}' not found."
  exit 1
fi
success "Deployment '${TARGET_DEPLOYMENT}' found"

# -----------------------------------------------------------------------------
# Step 2: Scale up target
# -----------------------------------------------------------------------------
step "Step 2: Scaling up ${TARGET_DEPLOYMENT} to 2 replicas"
kubectl scale deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" --replicas=2
success "Scale command issued"

# -----------------------------------------------------------------------------
# Step 3: Wait for rollout
# -----------------------------------------------------------------------------
step "Step 3: Waiting for ${TARGET_DEPLOYMENT} to be ready"
kubectl rollout status deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" --timeout=300s
success "Rollout complete"

# -----------------------------------------------------------------------------
# Step 4: Health checks on every target pod
# -----------------------------------------------------------------------------
step "Step 4: Running health checks"
mapfile -t TARGET_PODS < <(kubectl get pods -n "${NAMESPACE}" \
  -l "app=${SERVICE},version=${TARGET}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [ "${#TARGET_PODS[@]}" -eq 0 ]; then
  error "No pods found for ${TARGET_DEPLOYMENT}."
  kubectl scale deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" --replicas=0
  exit 1
fi

ALL_HEALTHY=true
for POD in "${TARGET_PODS[@]}"; do
  STATUS=$(kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')
  READY=$(kubectl get pod "${POD}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  if [ "${STATUS}" = "Running" ] && [ "${READY}" = "True" ]; then
    success "Pod ${POD}: phase=${STATUS}, ready=${READY}"
  else
    error "Pod ${POD}: phase=${STATUS}, ready=${READY}"
    ALL_HEALTHY=false
  fi
done

if [ "${ALL_HEALTHY}" != "true" ]; then
  echo ""
  error "Not all target pods are healthy. Aborting switch."
  info "Scaling down ${TARGET_DEPLOYMENT} to 0."
  kubectl scale deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" --replicas=0
  exit 1
fi

success "All pods healthy"

# -----------------------------------------------------------------------------
# Step 5: Confirmation prompt
# -----------------------------------------------------------------------------
echo ""
read -r -p "$(echo -e "${YELLOW}Switch traffic to ${BOLD}${TARGET}${RESET}${YELLOW}?${RESET} (y/N): ")" CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  info "Aborted. Scaling down ${TARGET_DEPLOYMENT}."
  kubectl scale deployment "${TARGET_DEPLOYMENT}" -n "${NAMESPACE}" --replicas=0
  exit 0
fi

# -----------------------------------------------------------------------------
# Step 6: Switch service selector
# -----------------------------------------------------------------------------
step "Step 6: Switching service selector to ${TARGET}"
kubectl patch svc "${SERVICE}" -n "${NAMESPACE}" \
  -p "{\"spec\":{\"selector\":{\"version\":\"${TARGET}\"}}}"
success "Service selector updated → ${TARGET}"

# -----------------------------------------------------------------------------
# Step 7: Verify endpoints
# -----------------------------------------------------------------------------
step "Step 7: Verifying service endpoints"
kubectl get endpoints "${SERVICE}" -n "${NAMESPACE}"

# -----------------------------------------------------------------------------
# Step 8: Optionally scale down old deployment
# -----------------------------------------------------------------------------
echo ""
read -r -p "$(echo -e "${YELLOW}Scale down old deployment ${BOLD}${SERVICE}-${CURRENT}${RESET}${YELLOW}?${RESET} (y/N): ")" SCALEDOWN
if [[ "${SCALEDOWN}" = "y" || "${SCALEDOWN}" = "Y" ]]; then
  kubectl scale deployment "${SERVICE}-${CURRENT}" -n "${NAMESPACE}" --replicas=0
  success "Old deployment scaled down"
else
  info "Old deployment kept running for instant rollback."
fi

echo ""
echo -e "${GREEN}${BOLD}=== Switch complete ===${RESET}"
info "  Active version: ${BOLD}${TARGET}${RESET}"
info "  Rollback:       kubectl patch svc ${SERVICE} -n ${NAMESPACE} -p '{\"spec\":{\"selector\":{\"version\":\"${CURRENT}\"}}}'"
echo ""
