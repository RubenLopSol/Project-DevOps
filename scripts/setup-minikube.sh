#!/bin/bash
# =============================================================================
# setup-minikube.sh — local Kubernetes cluster bootstrap
#
# Run this once on a fresh machine before anything else. It builds a 3-node
# Minikube cluster shaped like a tiny prod node-pool layout: one node per
# role (control-plane, app, observability). Every workload is pinned to its
# pool with nodeSelector, so observability pods can't use the app tier's
# resources and vice versa.
#
# Usage:
#   ./scripts/setup-minikube.sh
#
# What happens, in order:
#   1. Check minikube, kubectl and docker are on PATH
#   2. Start the cluster (skipped if it's already up)
#   3. Wait until every node reports Ready
#   4. Label the two workers (workload=app / workload=observability). The
#      control-plane keeps its NoSchedule taint so app pods can't land there
#   5. Bump inotify limits so Promtail doesn't run out of watch handles
#   6. Apply the base Kubernetes namespaces
#   7. Install the local-path storage provisioner
#   8. Add the service hostnames to /etc/hosts
#
# Node layout:
#   devops-cluster       control-plane (tainted) — kube-apiserver, etcd,
#                                                  ingress-nginx, ArgoCD
#                                                  server, cert-manager
#   devops-cluster-m02   workload=app            — OpenPanel API, Worker,
#                                                  Start, PostgreSQL,
#                                                  Redis, ClickHouse
#   devops-cluster-m03   workload=observability  — Prometheus, Grafana,
#                                                  Loki + storage,
#                                                  Tempo + storage,
#                                                  Alertmanager, caches
#
# Promtail is the only thing that runs everywhere — it's a DaemonSet, so
# logs from the app node and the control-plane both make it back to Loki
# on the obs node.
# =============================================================================

set -euo pipefail

# =============================================================================

CLUSTER_NAME="devops-cluster"
K8S_VERSION="v1.28.0"
NODES=3
CPUS=2          # per node 
MEMORY="2560"   # MiB per node — 2.5 GiB
DISK="40g"      # per node
DRIVER="docker"


NODE_CTRL="${CLUSTER_NAME}"       # control-plane — stays tainted, no workload label
NODE_APP="${CLUSTER_NAME}-m02"    # worker        — label workload=app
NODE_OBS="${CLUSTER_NAME}-m03"    # worker        — label workload=observability


LABEL_KEY="workload"
LABEL_APP="app"
LABEL_OBS="observability"


DNS_HOSTS="openpanel.local api.openpanel.local argocd.local grafana.local prometheus.local"

# Minimum Minikube version — v1.31+ is required for Kubernetes v1.28
MINIKUBE_MIN_MAJOR=1
MINIKUBE_MIN_MINOR=31


# =============================================================================
# Terminal colors 
# =============================================================================
COLOR_BOLD='\033[1m'     # bold text — no color change, just weight
COLOR_NONE='\033[0m'     # reset — clears all color and formatting
COLOR_ERROR='\033[0;31m'  # red — errors and things that stop execution
COLOR_SUCCESS='\033[0;32m'  # green — success messages and confirmations
COLOR_WARNING='\033[1;33m'  # yellow — warnings, skips, and cautions
COLOR_INFO='\033[0;36m'  # cyan — section headers and informational output


BOLD='\033[1m'
NONE='\033[0m'
ERROR='\033[0;31m'
SUCCESS='\033[0;32m'
WARNING='\033[1;33m'
INFO='\033[0;36m'


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
# Step 1 — Check required tools
#
# Three things have to be on PATH: minikube, kubectl, docker. If any are
# missing we list all of them before bailing out, so you can install the
# whole set in one go instead of running the script three times.
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
# Step 3 — Wait until every node reports Ready
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
# =============================================================================
label_nodes() {
  header "Assigning workload labels to nodes"

  # Make sure the worker nodes exist before attempting to label them.
  for node in "${NODE_APP}" "${NODE_OBS}"; do
    if ! kubectl get node "${node}" &>/dev/null; then
      fail "Node '${node}' was not found in the cluster."
      note "Check actual node names with: kubectl get nodes"
      exit 1
    fi
  done

  step "Leaving control-plane (${NODE_CTRL}) tainted — only system addons run there"
  success "Control-plane taint preserved"

  step "Labelling ${NODE_APP} as the application node"
  kubectl label node "${NODE_APP}" "${LABEL_KEY}=${LABEL_APP}" --overwrite
  success "${NODE_APP}  →  ${LABEL_KEY}=${LABEL_APP}  (OpenPanel API, Worker, PostgreSQL, Redis, ClickHouse)"

  step "Labelling ${NODE_OBS} as the observability node"
  kubectl label node "${NODE_OBS}" "${LABEL_KEY}=${LABEL_OBS}" --overwrite
  success "${NODE_OBS}  →  ${LABEL_KEY}=${LABEL_OBS}  (Prometheus, Grafana, Loki+storage, Tempo+storage)"

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
# Step 5 — Raise inotify limits on every node
#
# Promtail uses inotify to watch pod log files. The default kernel limits
# run out fast once having a lot of containers.
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
# =============================================================================
header "Creating Kubernetes namespaces"

kubectl apply -f k8s/infrastructure/base/namespaces/namespaces.yaml
echo ""
kubectl get namespaces


# =============================================================================
# Step 7 — Install the local-path storage provisioner
#
# Minikube's built-in provisioner always creates PV directories on the
# control-plane node, no matter where the pod is scheduled. That kills our
# nodeSelectors: a database pod pinned to the app node ends up with its
# data sitting on a node it can't reach.
#
# Rancher's local-path provisioner puts the directory on whichever node
# the pod is actually running on
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
# Step 8 — Local DNS in /etc/hosts
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
