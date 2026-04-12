#!/bin/bash
# =============================================================================
# setup-minikube.sh — Local Kubernetes Cluster Bootstrap
#
# Run this script once on a fresh machine before deploying anything.
# It creates a 3-node Minikube cluster that mirrors a real production
# environment, assigns each node a dedicated role, creates namespaces,
# and configures local DNS so every service is reachable by hostname.
#
# Usage:
#   ./scripts/setup-minikube.sh
#
# What it does, in order:
#   1. Checks that minikube, kubectl and docker are installed
#   2. Creates the cluster (skips if already running)
#   3. Waits for all nodes to become Ready
#   4. Labels each node by workload type
#   5. Increases inotify limits (required for Promtail log watching)
#   6. Creates the base Kubernetes namespaces
#   7. Installs the local-path storage provisioner
#   8. Adds all service hostnames to /etc/hosts
#
# Node layout:
#   devops-cluster       control-plane — Kubernetes internals only
#   devops-cluster-m02   app node      — OpenPanel API, Worker, databases
#   devops-cluster-m03   observability — Prometheus, Grafana, Loki, Tempo
#
# Why 3 nodes?
#   Separating workloads across nodes mirrors real production node pools
#   where you typically keep observability tools isolated from application
#   traffic. It also prevents a heavy scrape job from starving the API.
#
# Resource footprint:
#   Each node gets 4 CPUs, 4 GB RAM and 40 GB disk → 12 CPUs / 12 GB / 120 GB total
# =============================================================================

set -euo pipefail


# =============================================================================
# Configuration
# All values that might need changing are declared here at the top.
# Nothing is hardcoded deeper in the script.
# =============================================================================

CLUSTER_NAME="devops-cluster"
K8S_VERSION="v1.28.0"
NODES=3
CPUS=4
MEMORY="4096"   # MiB per node
DISK="40g"      # per node
DRIVER="docker"

# Worker node names follow Minikube's multi-node naming convention
NODE_APP="${CLUSTER_NAME}-m02"   # receives label workload=app
NODE_OBS="${CLUSTER_NAME}-m03"   # receives label workload=observability

# Node labels — these must match the nodeSelector in every K8s manifest.
# If you change them here, update the manifests in k8s/apps/base/ as well.
LABEL_KEY="workload"
LABEL_APP="app"
LABEL_OBS="observability"

# Local hostnames added to /etc/hosts so you can reach services by name
# instead of by IP. All entries point to the same Minikube IP — the
# ingress controller handles routing from there.
DNS_HOSTS="openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local"

# Minimum Minikube version — v1.31+ is required for Kubernetes v1.28
MINIKUBE_MIN_MAJOR=1
MINIKUBE_MIN_MINOR=31


# =============================================================================
# Terminal colors — named by purpose, not by color
# =============================================================================
COLOR_BOLD='\033[1m'     # bold text — no color change, just weight
COLOR_NONE='\033[0m'     # reset — clears all color and formatting
COLOR_ERROR='\033[0;31m'  # red — errors and things that stop execution
COLOR_SUCCESS='\033[0;32m'  # green — success messages and confirmations
COLOR_WARNING='\033[1;33m'  # yellow — warnings, skips, and cautions
COLOR_INFO='\033[0;36m'  # cyan — section headers and informational output

# Redefine as local shell variables (bash does not support = in variable names)
BOLD='\033[1m'
NONE='\033[0m'
ERROR='\033[0;31m'
SUCCESS='\033[0;32m'
WARNING='\033[1;33m'
INFO='\033[0;36m'


# =============================================================================
# Output helpers — consistent formatting throughout the script
# =============================================================================

# Top-level section title
header() {
  echo -e "\n${INFO}${BOLD}▶  $*${NONE}"
  echo -e "${INFO}   $(printf '─%.0s' {1..50})${NONE}"
}

# Individual step within a section
step() {
  echo -e "${WARNING}   →  $*${NONE}"
}

# Positive outcome
success() {
  echo -e "${SUCCESS}${BOLD}   ✔  $*${NONE}"
}

# Error — printed to stderr, script exits after calling this
fail() {
  echo -e "${ERROR}${BOLD}   ✖  $*${NONE}" >&2
}

# Plain indented note
note() {
  echo -e "      $*"
}


# =============================================================================
# Step 1 — Check that all required tools are installed
#
# We check for the three tools this script depends on: minikube, kubectl and
# docker. If any are missing we list them all before exiting so you can
# install everything in one go rather than discovering them one by one.
# =============================================================================
check_prerequisites() {
  header "Checking required tools"

  local missing=0

  for cmd in minikube kubectl docker; do
    if ! command -v "${cmd}" &>/dev/null; then
      fail "'${cmd}' is not installed or not in PATH"
      missing=1
    else
      success "${cmd} is available at $(command -v ${cmd})"
    fi
  done

  if [ "${missing}" -eq 1 ]; then
    echo ""
    fail "Please install the missing tools above and run this script again."
    echo ""
    note "minikube  →  https://minikube.sigs.k8s.io/docs/start/"
    note "kubectl   →  https://kubernetes.io/docs/tasks/tools/"
    note "docker    →  https://docs.docker.com/get-docker/"
    echo ""
    exit 1
  fi

  # Minikube version check — older versions do not support Kubernetes v1.28
  step "Checking Minikube version (need v${MINIKUBE_MIN_MAJOR}.${MINIKUBE_MIN_MINOR} or newer)"

  local raw_ver
  raw_ver=$(minikube version --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  if [ -z "${raw_ver}" ]; then
    fail "Could not read the Minikube version. Try running: minikube version"
    exit 1
  fi

  local major minor
  major=$(echo "${raw_ver}" | cut -d. -f1 | tr -d 'v')
  minor=$(echo "${raw_ver}" | cut -d. -f2)

  if [ "${major}" -lt "${MINIKUBE_MIN_MAJOR}" ] || \
     { [ "${major}" -eq "${MINIKUBE_MIN_MAJOR}" ] && [ "${minor}" -lt "${MINIKUBE_MIN_MINOR}" ]; }; then
    fail "Minikube ${raw_ver} is too old — v${MINIKUBE_MIN_MAJOR}.${MINIKUBE_MIN_MINOR}+ is required"
    note "Upgrade guide: https://minikube.sigs.k8s.io/docs/start/"
    exit 1
  fi

  success "Minikube ${raw_ver} — version requirement met"
}


# =============================================================================
# Step 3 — Wait for all nodes to report Ready
#
# Minikube returns from `minikube start` before all nodes have fully joined
# the cluster. Labelling a node that is still initialising causes a
# "node not found" error, so we poll until every node is Ready.
# =============================================================================
wait_for_nodes() {
  local max_attempts=30
  local attempt=0

  step "Waiting for all ${NODES} nodes to become Ready..."

  until [ "$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')" -ge "${NODES}" ]; do
    attempt=$((attempt + 1))
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      fail "Nodes did not become Ready after $((max_attempts * 10)) seconds."
      echo ""
      kubectl get nodes
      exit 1
    fi
    note "Attempt ${attempt}/${max_attempts} — waiting 10 seconds..."
    sleep 10
  done

  success "All ${NODES} nodes are Ready"
}


# =============================================================================
# Step 4 — Label each worker node by workload type
#
# Labels tell the Kubernetes scheduler where to place each pod. Every manifest
# in this repo carries a matching nodeSelector, so pods are pinned to the
# correct node and cannot drift to the wrong one.
#
# Promtail is the only exception — it runs as a DaemonSet which means one
# instance per node. It must collect logs from every node, not just the
# observability node, so it has no nodeSelector.
# =============================================================================
label_nodes() {
  header "Assigning workload labels to nodes"

  # Make sure both worker nodes exist before attempting to label them
  for node in "${NODE_APP}" "${NODE_OBS}"; do
    if ! kubectl get node "${node}" &>/dev/null; then
      fail "Node '${node}' was not found in the cluster."
      note "Check actual node names with: kubectl get nodes"
      exit 1
    fi
  done

  step "Labelling ${NODE_APP} as the application node"
  kubectl label node "${NODE_APP}" "${LABEL_KEY}=${LABEL_APP}" --overwrite
  success "${NODE_APP}  →  ${LABEL_KEY}=${LABEL_APP}  (OpenPanel API, Worker, PostgreSQL, Redis, ClickHouse)"

  step "Labelling ${NODE_OBS} as the observability node"
  kubectl label node "${NODE_OBS}" "${LABEL_KEY}=${LABEL_OBS}" --overwrite
  success "${NODE_OBS}  →  ${LABEL_KEY}=${LABEL_OBS}  (Prometheus, Grafana, Loki, Tempo)"

  echo ""
  note "Promtail runs on ALL nodes as a DaemonSet — it collects logs from every pod"
  echo ""

  kubectl get nodes --show-labels | grep -E 'NAME|workload'
}


# =============================================================================
# Main — runs each step in order
# =============================================================================

check_prerequisites


# =============================================================================
# Step 2 — Create the cluster (or skip if it is already running)
# =============================================================================
header "Setting up the Minikube cluster"

if minikube status --profile="${CLUSTER_NAME}" &>/dev/null; then
  note "Cluster '${BOLD}${CLUSTER_NAME}${NONE}' is already running — skipping creation."
else
  step "Creating a ${NODES}-node cluster with Kubernetes ${K8S_VERSION}"
  note "Driver: ${DRIVER}  |  Per node: ${CPUS} CPUs · ${MEMORY} MiB RAM · ${DISK} disk"
  note "Total resources: $((CPUS * NODES)) CPUs · $((${MEMORY} * NODES / 1024)) GiB RAM · ${DISK%g}×${NODES} GiB disk"
  echo ""

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

  success "Cluster created successfully"
fi

header "Verifying cluster connectivity"
kubectl cluster-info --context="${CLUSTER_NAME}" 2>/dev/null || kubectl cluster-info
echo ""
kubectl get nodes -o wide


wait_for_nodes
label_nodes


# =============================================================================
# Step 5 — Increase inotify limits on every node
#
# Promtail watches pod log files using Linux inotify. The default kernel
# limits are too low when many containers are running simultaneously.
# We raise them on all three nodes so Promtail never hits "too many open files".
# =============================================================================
header "Raising inotify limits for Promtail log watching"

for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  step "Applying inotify limits on ${node}"
  minikube ssh -p "${CLUSTER_NAME}" -n "${node}" -- \
    "sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288" 2>/dev/null \
    || minikube ssh -p "${CLUSTER_NAME}" -- \
       "sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288" 2>/dev/null \
    || true
done

success "inotify limits applied on all nodes"


# =============================================================================
# Step 6 — Create Kubernetes namespaces
#
# All namespaces are declared in a single manifest so they can be tracked
# in Git and applied idempotently. Creating them before ArgoCD boots means
# ArgoCD never tries to create a namespace that already exists.
# =============================================================================
header "Creating Kubernetes namespaces"

kubectl apply -f k8s/infrastructure/base/namespaces/namespaces.yaml
echo ""
kubectl get namespaces


# =============================================================================
# Step 7 — Install the local-path storage provisioner
#
# The default Minikube storage provisioner creates PersistentVolume directories
# on the control-plane node regardless of where the pod is actually scheduled.
# This breaks nodeSelectors — a database pod pinned to the app node cannot
# access its data if the directory is on the control-plane node.
#
# Rancher's local-path provisioner creates the directory on the node where
# the pod runs, which is exactly what we need for a multi-node setup.
# =============================================================================
header "Installing local-path storage provisioner"

note "This replaces the default Minikube provisioner with a topology-aware one."
note "It creates PersistentVolume directories on the node where the pod runs."
echo ""

kubectl apply -k k8s/infrastructure/base/local-path-provisioner

kubectl wait deployment/local-path-provisioner \
  --namespace=local-path-storage \
  --for=condition=available \
  --timeout=90s

success "Storage provisioner installed — StorageClass 'local-path' is ready"


# =============================================================================
# Step 8 — Configure /etc/hosts for local DNS
#
# The ingress controller exposes all services on the Minikube IP.
# Adding hostnames to /etc/hosts lets you use friendly URLs like
# http://openpanel.local instead of remembering the IP address.
# If an entry already exists (e.g. from a previous run), we update it.
# =============================================================================
header "Configuring local DNS in /etc/hosts"

MINIKUBE_IP=$(minikube ip --profile="${CLUSTER_NAME}")
read -r FIRST_HOST _ <<< "${DNS_HOSTS}"

step "Minikube cluster IP: ${MINIKUBE_IP}"

if grep -q "${FIRST_HOST}" /etc/hosts; then
  note "Existing entry found — removing old IP and updating..."
  sudo sed -i "/${FIRST_HOST}/d" /etc/hosts
fi

echo "${MINIKUBE_IP}  ${DNS_HOSTS}" | sudo tee -a /etc/hosts > /dev/null

success "/etc/hosts updated"
note "${MINIKUBE_IP}  ${DNS_HOSTS}"


# =============================================================================
# Done — print a summary and next steps
# =============================================================================
echo ""
echo -e "${INFO}${BOLD}   ══════════════════════════════════════════════════${NONE}"
echo -e "${SUCCESS}${BOLD}   ✔  Cluster setup complete${NONE}"
echo -e "${INFO}${BOLD}   ══════════════════════════════════════════════════${NONE}"
echo ""
note "Cluster name  :  ${BOLD}${CLUSTER_NAME}${NONE}  (${NODES} nodes)"
note "Cluster IP    :  ${BOLD}${MINIKUBE_IP}${NONE}"
note "App node      :  ${NODE_APP}  →  ${LABEL_KEY}=${LABEL_APP}"
note "Obs node      :  ${NODE_OBS}  →  ${LABEL_KEY}=${LABEL_OBS}"
echo ""
echo -e "${WARNING}${BOLD}   Next steps:${NONE}"
note "1. Install ArgoCD              →  ./scripts/install-argocd.sh"
note "2. Bootstrap the App of Apps  →  kubectl apply -f k8s/infrastructure/overlays/staging/argocd/bootstrap-app.yaml"
note "3. Open ArgoCD UI             →  http://argocd.local"
echo ""
