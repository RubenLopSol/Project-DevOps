#!/bin/bash
set -euo pipefail

# =============================================================================
# Cluster bootstrap — DevOps Master Project
#
# Run this once on a fresh machine before anything else.
# It brings up a 3-node local Kubernetes cluster, labels each node by
# workload type, creates the base namespaces, and wires up /etc/hosts
# so every service is reachable by its local hostname.
#
# Usage:
#   ./scripts/setup-minikube.sh
#
# The cluster is named "devops-cluster" — not after any specific application —
# because it is a shared platform that can host multiple workloads.
# Three nodes are created to mirror real production node pools:
#
#   devops-cluster       node 1 — control-plane (Kubernetes internals only)
#   devops-cluster-m02   node 2 — app workloads (OpenPanel API, Worker, databases)
#   devops-cluster-m03   node 3 — observability (Prometheus, Grafana, Loki, Tempo)
#
# Once the nodes are Ready, workers are labelled workload=app and
# workload=observability. Every manifest in the repo carries a matching
# nodeSelector, so Kubernetes enforces the placement — no pod can drift
# onto the wrong node by accident.
#
# Promtail has no nodeSelector on purpose: as a DaemonSet it must run
# on every node to collect logs from all pods, not just the obs node.
#
# Resource footprint (per node × 3):
#   CPU    4 cores  →  12 total
#   Memory 4Gi      →  12Gi total
#   Disk   40Gi     →  120Gi total
# =============================================================================

# Generic cluster name 
CLUSTER_NAME="devops-cluster"
K8S_VERSION="v1.28.0"
NODES=3           # control-plane + 2 worker nodes
CPUS=4            # per node
MEMORY="4096"     # per node (MiB)
DISK="40g"        # per node
DRIVER="docker"

# Node names derived from Minikube multi-node naming convention
NODE_APP="${CLUSTER_NAME}-m02"      # app workloads
NODE_OBS="${CLUSTER_NAME}-m03"      # observability workloads

# Node group labels — must match the nodeSelector in every K8s manifest.
# Change these here and update kustomization nodeSelector values accordingly.
LABEL_KEY="workload"
LABEL_APP="app"
LABEL_OBS="observability"

# Local DNS hostnames added to /etc/hosts so services are reachable by name.
# All entries point to the same Minikube IP (ingress controller handles routing).
DNS_HOSTS="openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local"

MINIKUBE_MIN_MAJOR=1
MINIKUBE_MIN_MINOR=31   # v1.31+ required for Kubernetes v1.28; multi-node since v1.10

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

# Check that the required tools are installed and at the right version.
check_prerequisites() {
  local missing=0

  header "Checking prerequisites"
  for cmd in minikube kubectl docker; do
    if ! command -v "${cmd}" &>/dev/null; then
      error "'${cmd}' is not installed or not in PATH"
      missing=1
    else
      success "${cmd} found"
    fi
  done

  if [ "${missing}" -eq 1 ]; then
    echo ""
    error "Install missing tools and re-run this script."
    exit 1
  fi

  # Minikube minimum version check
  step "Checking Minikube version (minimum v${MINIKUBE_MIN_MAJOR}.${MINIKUBE_MIN_MINOR})"
  MINIKUBE_RAW=$(minikube version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  MINIKUBE_MAJOR=$(echo "${MINIKUBE_RAW}" | cut -d. -f1 | tr -d 'v')
  MINIKUBE_MINOR=$(echo "${MINIKUBE_RAW}" | cut -d. -f2)

  if [ -z "${MINIKUBE_MAJOR}" ]; then
    error "Could not determine Minikube version. Output: $(minikube version --short 2>&1 || true)"
    exit 1
  fi

  if [ "${MINIKUBE_MAJOR}" -lt "${MINIKUBE_MIN_MAJOR}" ] || \
     { [ "${MINIKUBE_MAJOR}" -eq "${MINIKUBE_MIN_MAJOR}" ] && [ "${MINIKUBE_MINOR}" -lt "${MINIKUBE_MIN_MINOR}" ]; }; then
    error "Minikube v${MINIKUBE_MIN_MAJOR}.${MINIKUBE_MIN_MINOR}+ is required. Found: ${MINIKUBE_RAW}"
    info "Upgrade Minikube: https://minikube.sigs.k8s.io/docs/start/"
    exit 1
  fi

  success "Minikube ${MINIKUBE_RAW} — OK"
}

# Block until all nodes report Ready.
# Without this, the label step below can run before a node has fully joined
# the cluster, causing "node not found" errors.
wait_for_nodes() {
  local max_attempts=30
  local attempt=0

  step "Waiting for all ${NODES} nodes to be Ready..."
  until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')" -ge "${NODES}" ]; do
    attempt=$((attempt + 1))
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      error "Not all nodes became Ready after ${max_attempts} attempts."
      kubectl get nodes
      exit 1
    fi
    info "Attempt ${attempt}/${max_attempts} — retrying in 10s..."
    sleep 10
  done
  success "All ${NODES} nodes are Ready"
}

# Attach a workload label to each worker node so that nodeSelectors in the
# manifests route pods to the right node.
label_nodes() {
  header "Labelling node groups"

  # Verify the worker nodes exist before labelling
  for node in "${NODE_APP}" "${NODE_OBS}"; do
    if ! kubectl get node "${node}" &>/dev/null; then
      error "Node '${node}' not found. Check cluster node names with: kubectl get nodes"
      exit 1
    fi
  done

  step "node 2 → ${LABEL_KEY}=${LABEL_APP}            (${NODE_APP})"
  kubectl label node "${NODE_APP}" "${LABEL_KEY}=${LABEL_APP}" --overwrite
  success "Labelled ${NODE_APP}: ${LABEL_KEY}=${LABEL_APP}"

  step "node 3 → ${LABEL_KEY}=${LABEL_OBS}  (${NODE_OBS})"
  kubectl label node "${NODE_OBS}" "${LABEL_KEY}=${LABEL_OBS}" --overwrite
  success "Labelled ${NODE_OBS}: ${LABEL_KEY}=${LABEL_OBS}"

  info ""
  info "  App workloads (openpanel-api, postgres, redis, clickhouse, worker)"
  info "  will schedule exclusively on ${BOLD}${NODE_APP}${RESET} (${LABEL_KEY}=${LABEL_APP})"
  info "  Observability stack (Prometheus, Grafana, Loki, Tempo)"
  info "  will schedule exclusively on ${BOLD}${NODE_OBS}${RESET} (${LABEL_KEY}=${LABEL_OBS})"
  info "  Promtail runs on ALL nodes (DaemonSet — collects logs from every node)"

  echo ""
  kubectl get nodes --show-labels | grep -E 'NAME|workload'
}

check_prerequisites

header "Checking cluster status"
if minikube status --profile="${CLUSTER_NAME}" &>/dev/null; then
  info "Cluster '${BOLD}${CLUSTER_NAME}${RESET}' is already running. Skipping creation."
else
  header "Starting Minikube cluster: ${CLUSTER_NAME}"
  step "Kubernetes ${K8S_VERSION} · ${NODES} nodes · driver=${DRIVER}"
  step "Per-node: CPUs=${CPUS} · memory=${MEMORY}MiB · disk=${DISK}"
  step "Total:    CPUs=$((CPUS * NODES)) · memory=$((${MEMORY%MiB} * NODES / 1024))Gi · disk=${DISK%g}×${NODES}Gi"

  minikube start \
    --profile="${CLUSTER_NAME}" \
    --kubernetes-version="${K8S_VERSION}" \
    --driver="${DRIVER}" \
    --nodes="${NODES}" \
    --cpus="${CPUS}" \
    --memory="${MEMORY}" \
    --disk-size="${DISK}" \
    --addons=ingress \
    --addons=metrics-server \
    --addons=storage-provisioner

  success "Cluster started"
fi

header "Verifying cluster"

kubectl cluster-info --context="${CLUSTER_NAME}" 2>/dev/null || kubectl cluster-info
kubectl get nodes -o wide

wait_for_nodes
label_nodes

# ---------------------------------------------------------------------------
# Set inotify limits on all nodes so Promtail (DaemonSet) can watch pod log
# files without hitting the default kernel limit ("too many open files").
# ---------------------------------------------------------------------------
header "Configuring inotify limits (required for Promtail)"
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  step "Setting inotify limits on ${node}"
  minikube ssh -p "${CLUSTER_NAME}" -n "${node}" -- \
    "sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288" 2>/dev/null \
    || minikube ssh -p "${CLUSTER_NAME}" -- \
       "sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288" 2>/dev/null \
    || true
done
success "inotify limits configured on all nodes"

header "Creating namespaces"
kubectl apply -f k8s/infrastructure/base/namespaces/namespaces.yaml
kubectl get namespaces

# ---------------------------------------------------------------------------
# Install local-path-provisioner (Rancher) to provide a topology-aware
# StorageClass "local-path". Unlike the default minikube hostpath provisioner
# which creates all PV directories on the primary node, local-path creates the
# directory on the node where the pod is actually scheduled — required for
# nodeSelectors to work correctly with persistent storage in multi-node setups.
# ---------------------------------------------------------------------------
header "Installing local-path-provisioner (topology-aware PV provisioner)"
kubectl apply -k k8s/infrastructure/base/local-path-provisioner
kubectl wait deployment/local-path-provisioner \
  -n local-path-storage \
  --for=condition=available \
  --timeout=90s
success "local-path-provisioner installed — StorageClass 'local-path' is ready"

MINIKUBE_IP=$(minikube ip --profile="${CLUSTER_NAME}")
read -r FIRST_HOST _ <<< "$DNS_HOSTS"

header "Configuring /etc/hosts"
step "Cluster IP: ${MINIKUBE_IP}"
if grep -q "${FIRST_HOST}" /etc/hosts; then
  info "Existing entry found — updating IP..."
  sudo sed -i "/${FIRST_HOST}/d" /etc/hosts
fi
echo "${MINIKUBE_IP}  ${DNS_HOSTS}" | sudo tee -a /etc/hosts > /dev/null
success "/etc/hosts updated: ${BOLD}${MINIKUBE_IP}  ${DNS_HOSTS}${RESET}"

echo ""
echo -e "${GREEN}${BOLD}=== Setup complete ===${RESET}"
echo ""
success "Cluster:  ${BOLD}${CLUSTER_NAME}${RESET} (${NODES} nodes)"
success "Node labels: ${NODE_APP} → ${LABEL_KEY}=${LABEL_APP}"
success "             ${NODE_OBS} → ${LABEL_KEY}=${LABEL_OBS}"
success "Cluster IP: ${BOLD}${MINIKUBE_IP}${RESET}"
success "/etc/hosts configured for all services"
echo ""
info "Next steps:"
info "  1. helm install sealed-secrets ..."
info "  2. kubectl apply -f k8s/infrastructure/base/sealed-secrets/secrets.yaml"
info "  3. ./scripts/install-argocd.sh"
echo ""
