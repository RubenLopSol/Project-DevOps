#!/bin/bash
set -euo pipefail

# =============================================================================
# Backup and Restore operations for OpenPanel
#
# Usage:
#   ./scripts/backup-restore.sh backup [namespace]
#   ./scripts/backup-restore.sh backup-db [namespace]
#   ./scripts/backup-restore.sh restore <backup-name>
#   ./scripts/backup-restore.sh list
#   ./scripts/backup-restore.sh help
#
# Examples:
#   ./scripts/backup-restore.sh backup
#   ./scripts/backup-restore.sh backup openpanel
#   ./scripts/backup-restore.sh backup-db
#   ./scripts/backup-restore.sh restore manual-backup-20241107-143000
#   ./scripts/backup-restore.sh list
# =============================================================================

ACTION="${1:-help}"
# NAMESPACE and BACKUP_NAME are only used by specific actions — parsed inside each case
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Chrome goes to stderr so functions like wait_for_pod can return data
# on stdout via $(...) without it being polluted by progress messages.
header()  { echo -e "\n${CYAN}${BOLD}=== $* ===${RESET}" >&2; }
step()    { echo -e "${YELLOW}--- $* ---${RESET}" >&2; }
success() { echo -e "${GREEN}${BOLD}✔ $*${RESET}" >&2; }
error()   { echo -e "${RED}${BOLD}✖ ERROR: $*${RESET}" >&2; }
info()    { echo -e "  $*" >&2; }

# -----------------------------------------------------------------------------
# Prerequisite checks
# -----------------------------------------------------------------------------
check_prerequisites() {
  local missing=0

  for cmd in "$@"; do
    if ! command -v "${cmd}" &>/dev/null; then
      error "'${cmd}' is not installed or not in PATH"
      missing=1
    fi
  done

  if [ "${missing}" -eq 1 ]; then
    exit 1
  fi
}

# Wait for a pod to be in Running state
wait_for_pod() {
  local namespace="${1}"
  local label="${2}"
  local max_attempts=12

  step "Waiting for pod with label '${label}' in namespace '${namespace}'..."
  for attempt in $(seq 1 "${max_attempts}"); do
    POD=$(kubectl get pod -n "${namespace}" -l "${label}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${POD}" ]; then
      success "Pod found: ${POD}"
      echo "${POD}"
      return 0
    fi
    info "Attempt ${attempt}/${max_attempts} — retrying in 5s..."
    sleep 5
  done

  error "No pod found with label '${label}' in namespace '${namespace}'" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Actions
# -----------------------------------------------------------------------------
case "${ACTION}" in

  backup)
    check_prerequisites velero kubectl
    NAMESPACE="${2:-openpanel}"
    BACKUP_NAME="manual-backup-${TIMESTAMP}"
    header "Creating full Velero backup"
    info "  Backup name: ${BOLD}${BACKUP_NAME}${RESET}"
    info "  Namespace:   ${BOLD}${NAMESPACE}${RESET}"
    velero backup create "${BACKUP_NAME}" \
      --include-namespaces "${NAMESPACE}" \
      --wait
    echo ""
    velero backup describe "${BACKUP_NAME}"
    echo ""
    success "Backup complete: ${BACKUP_NAME}"
    ;;

  backup-db)
    check_prerequisites kubectl gzip
    NAMESPACE="${2:-openpanel}"
    header "Creating database backups (namespace: ${NAMESPACE})"

    # PostgreSQL
    step "PostgreSQL"
    PG_POD=$(wait_for_pod "${NAMESPACE}" "app=postgres")
    PG_FILE="backup-postgres-${TIMESTAMP}.sql.gz"
    kubectl exec -n "${NAMESPACE}" "${PG_POD}" -- \
      pg_dump -U openpanel openpanel | gzip > "${PG_FILE}"
    success "PostgreSQL backup saved: ${BOLD}${PG_FILE}${RESET}"

    # Redis
    step "Redis"
    REDIS_POD=$(wait_for_pod "${NAMESPACE}" "app=redis")
    kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli SAVE
    success "Redis RDB snapshot triggered"

    # ClickHouse
    step "ClickHouse"
    CH_POD=$(wait_for_pod "${NAMESPACE}" "app=clickhouse")
    CH_BACKUP_NAME="backup-clickhouse-${TIMESTAMP}"
    # Flush in-memory data to disk before snapshotting
    kubectl exec -n "${NAMESPACE}" "${CH_POD}" -- \
      clickhouse-client --query "SYSTEM FLUSH LOGS"
    # Native ClickHouse backup to a file inside the pod
    kubectl exec -n "${NAMESPACE}" "${CH_POD}" -- \
      clickhouse-client --query \
      "BACKUP DATABASE openpanel TO File('${CH_BACKUP_NAME}.zip')"
    success "ClickHouse backup saved inside pod: ${BOLD}${CH_BACKUP_NAME}.zip${RESET}"

    echo ""
    success "All database backups complete"
    ;;

  restore)
    check_prerequisites velero
    RESTORE_BACKUP="${2:-}"
    if [ -z "${RESTORE_BACKUP}" ]; then
      error "backup name is required for restore."
      echo ""
      info "Usage: $0 restore <backup-name>"
      echo ""
      info "Available backups:"
      velero backup get
      exit 1
    fi
    header "Restoring from backup: ${RESTORE_BACKUP}"
    velero restore create --from-backup "${RESTORE_BACKUP}" --wait
    success "Restore complete"
    ;;

  list)
    check_prerequisites velero
    header "Available backups"
    velero backup get
    ;;

  help|*)
    echo ""
    echo -e "${CYAN}${BOLD}OpenPanel Backup & Restore${RESET}"
    echo ""
    echo -e "  ${BOLD}Usage:${RESET} $0 <action> [namespace|backup-name]"
    echo ""
    echo -e "  ${BOLD}Actions:${RESET}"
    info "  ${YELLOW}backup${RESET} [namespace]       Full Velero backup of a namespace (default: openpanel)"
    info "  ${YELLOW}backup-db${RESET} [namespace]    Backup PostgreSQL, Redis, and ClickHouse individually"
    info "  ${YELLOW}restore${RESET} <backup-name>    Restore from a named Velero backup"
    info "  ${YELLOW}list${RESET}                     List all available Velero backups"
    info "  ${YELLOW}help${RESET}                     Show this help"
    echo ""
    ;;

esac
