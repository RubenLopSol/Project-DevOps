#!/usr/bin/env bash
# =============================================================================
# preflight.sh
#
# Verifies that every tool and configuration required by the local OpenPanel
# stack is present and correct BEFORE attempting to build or start containers.
#
# Invoked standalone via `make preflight`, and automatically as a dependency
# of `make dev-up`.
# =============================================================================

# Strict mode:
#   -e           exit on any command failure
#   -u           treat unset variables as errors
#   -o pipefail  propagate failures through pipes
set -euo pipefail
IFS=$'\n\t'


# -----------------------------------------------------------------------------
# Minimum required versions
# -----------------------------------------------------------------------------
readonly DOCKER_MIN_MAJOR=24
readonly COMPOSE_MIN_MAJOR=2
readonly COMPOSE_MIN_MINOR=20


# -----------------------------------------------------------------------------
# Terminal colors
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  readonly BOLD=$'\033[1m'
  readonly RESET=$'\033[0m'
  readonly RED=$'\033[0;31m'
  readonly GREEN=$'\033[0;32m'
  readonly YELLOW=$'\033[1;33m'
  readonly CYAN=$'\033[0;36m'
else
  readonly BOLD='' RESET='' RED='' GREEN='' YELLOW='' CYAN=''
fi


# -----------------------------------------------------------------------------
# Output helpers
#
#   header  — top-level banner at the start of the run
#   step    — label for the check about to run
#   ok      — check passed
#   die     — check failed; print remediation and exit non-zero
# -----------------------------------------------------------------------------
header() { printf '\n%s%s▶  %s%s\n'       "${CYAN}" "${BOLD}" "$1" "${RESET}"; }
step()   { printf '%s   →  %s%s\n'         "${YELLOW}"         "$1" "${RESET}"; }
ok()     { printf '   %s✔  %s%s\n'         "${GREEN}"          "$1" "${RESET}"; }
die()    { printf '   %s%s✖  %s%s\n'       "${RED}" "${BOLD}"  "$1" "${RESET}" >&2; exit 1; }


# -----------------------------------------------------------------------------
# version_ge  —  "is version $1 >= $2?"
#
# Compares two dotted version strings (e.g. "2.29.1" >= "2.20").
# -----------------------------------------------------------------------------
version_ge() {
  # Sort both versions; if the smaller of the two is $2, then $1 is >= $2.
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# =============================================================================
# Individual checks
# =============================================================================

check_docker_running() {
  step "Docker daemon is running"
  if ! docker info >/dev/null 2>&1; then
    die "Docker is not running — start Docker Desktop (or 'sudo systemctl start docker') and retry"
  fi
  ok "Docker daemon reachable"
}

check_docker_version() {
  step "Docker engine >= ${DOCKER_MIN_MAJOR}"
  local version major
  version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
  major=${version%%.*}

  if [[ -z "${version}" || ! "${major}" =~ ^[0-9]+$ ]]; then
    die "Could not determine Docker version — is the daemon reachable?"
  fi
  if (( major < DOCKER_MIN_MAJOR )); then
    die "Docker ${DOCKER_MIN_MAJOR}+ required (found ${version}) — upgrade: https://docs.docker.com/engine/install/"
  fi
  ok "Docker ${version}"
}

check_compose_version() {
  step "Docker Compose v${COMPOSE_MIN_MAJOR}.${COMPOSE_MIN_MINOR}+"
  local version
  version=$(docker compose version --short 2>/dev/null || true)

  if [[ -z "${version}" ]]; then
    die "Docker Compose v2 plugin not found — install: https://docs.docker.com/compose/install/"
  fi
  if ! version_ge "${version}" "${COMPOSE_MIN_MAJOR}.${COMPOSE_MIN_MINOR}"; then
    die "Compose v${COMPOSE_MIN_MAJOR}.${COMPOSE_MIN_MINOR}+ required (found ${version}) — upgrade Docker Desktop or the compose plugin"
  fi
  ok "Compose ${version}"
}

check_env_file() {
  step ".env file exists"
  if [[ ! -f .env ]]; then
    die ".env not found — run: cp .env.example .env  (then fill in the values)"
  fi
  ok ".env present"
}

check_hosts_entry() {
  step "/etc/hosts has host.docker.internal"
  if ! grep -qE '^[^#]*\bhost\.docker\.internal\b' /etc/hosts; then
    die "host.docker.internal missing from /etc/hosts — run: echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts"
  fi
  ok "host.docker.internal mapped"
}

check_jq_installed() {
  step "jq is installed"
  if ! command -v jq >/dev/null 2>&1; then
    die "jq not found — install: sudo apt install jq  (macOS: brew install jq)"
  fi
  ok "jq $(jq --version)"
}

check_sibling_fork() {
  step "sibling openpanel fork at ../openpanel"
  local fork_dir="../openpanel"
  local required=(
    "${fork_dir}/apps/api/Dockerfile"
    "${fork_dir}/apps/worker/Dockerfile"
    "${fork_dir}/apps/start/Dockerfile"
    "${fork_dir}/docker/clickhouse/clickhouse-config.xml"
  )

  if [[ ! -d "${fork_dir}" ]]; then
    die "${fork_dir} not found — clone the fork beside this repo:
         (cd .. && git clone https://github.com/RubenLopSol/openpanel.git)"
  fi

  local missing=()
  for f in "${required[@]}"; do
    [[ -f "${f}" ]] || missing+=("${f}")
  done

  if (( ${#missing[@]} > 0 )); then
    die "sibling fork is present but incomplete — missing: ${missing[*]}
         re-clone or pull upstream: (cd ${fork_dir} && git pull)"
  fi

  ok "sibling fork present at ${fork_dir}"
}


# =============================================================================
# Main
# =============================================================================
main() {
  header "Running pre-flight checks"

  check_docker_running
  check_docker_version
  check_compose_version
  check_env_file
  check_hosts_entry
  check_jq_installed
  check_sibling_fork

  printf '\n   %s%s✔  All pre-flight checks passed%s\n\n' \
    "${GREEN}" "${BOLD}" "${RESET}"
}

main "$@"
