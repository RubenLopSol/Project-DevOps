#!/bin/bash
set -euo pipefail

# Smoke tests for the deployed OpenPanel stack.
# These checks are intentionally small: they prove that the GitOps deployment
# reconciled, the API is reachable, the dashboard responds, and monitoring is up.

NAMESPACE="${NAMESPACE:-openpanel}"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"
API_SERVICE="${API_SERVICE:-openpanel-api}"
DASHBOARD_SERVICE="${DASHBOARD_SERVICE:-openpanel-start}"
PROMETHEUS_SERVICE="${PROMETHEUS_SERVICE:-prometheus-kube-prometheus-prometheus}"
API_HEALTH_PATH="${API_HEALTH_PATH:-/healthz/live}"
DASHBOARD_PATH="${DASHBOARD_PATH:-/}"
PROMETHEUS_READY_PATH="${PROMETHEUS_READY_PATH:-/-/ready}"
PORT_FORWARD_PID=""

cleanup() {
  if [ -n "${PORT_FORWARD_PID}" ] && kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

header() { echo ""; echo "=== $* ==="; }
step() { echo "--- $*"; }

wait_for_http() {
  local url="${1}"
  local attempts="${2:-30}"

  for attempt in $(seq 1 "${attempts}"); do
    if curl -fsS "${url}" >/dev/null; then
      echo "OK: ${url}"
      return 0
    fi

    echo "Attempt ${attempt}/${attempts}: waiting for ${url}"
    sleep 5
  done

  echo "ERROR: ${url} did not become reachable" >&2
  return 1
}

check_command() {
  if ! command -v "${1}" >/dev/null 2>&1; then
    echo "ERROR: '${1}' is required" >&2
    exit 1
  fi
}

check_command kubectl
check_command curl

header "OpenPanel smoke tests"

step "Checking application pods are Ready"
kubectl wait pod -n "${NAMESPACE}" \
  -l 'app in (openpanel-api,openpanel-start,openpanel-worker,postgres,redis,clickhouse)' \
  --for=condition=Ready \
  --timeout=300s

step "Checking API health through the cluster Service"
kubectl port-forward -n "${NAMESPACE}" "svc/${API_SERVICE}" 18080:3333 >/tmp/openpanel-api-smoke.log 2>&1 &
PORT_FORWARD_PID="${!}"
sleep 3
wait_for_http "http://127.0.0.1:18080${API_HEALTH_PATH}"
cleanup
PORT_FORWARD_PID=""

step "Checking dashboard responds through the cluster Service"
kubectl port-forward -n "${NAMESPACE}" "svc/${DASHBOARD_SERVICE}" 18081:3000 >/tmp/openpanel-dashboard-smoke.log 2>&1 &
PORT_FORWARD_PID="${!}"
sleep 3
wait_for_http "http://127.0.0.1:18081${DASHBOARD_PATH}"
cleanup
PORT_FORWARD_PID=""

step "Checking Prometheus readiness"
kubectl port-forward -n "${OBS_NAMESPACE}" "svc/${PROMETHEUS_SERVICE}" 19090:9090 >/tmp/openpanel-prometheus-smoke.log 2>&1 &
PORT_FORWARD_PID="${!}"
sleep 3
wait_for_http "http://127.0.0.1:19090${PROMETHEUS_READY_PATH}"

echo ""
echo "Smoke tests passed."