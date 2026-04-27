#!/bin/bash
# =============================================================================
#
# What this script does: drops mirror.gcr.io into /etc/docker/daemon.json
# as a registry mirror. From there, Docker Hub pulls get transparently
# routed through Google's read-only mirror, which sits on a different CDN
# and tends to be reachable everywhere.
#
# Usage:
#   sudo ./scripts/configure-docker-mirror.sh
#
# Restart docker afterwards so the mirror takes effect:
#   sudo systemctl restart docker
# =============================================================================

set -euo pipefail

DAEMON_JSON="/etc/docker/daemon.json"
MIRROR="https://mirror.gcr.io"

if [ "$(id -u)" -ne 0 ]; then
  echo "✖  Must be run as root. Try: sudo $0" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "✖  jq is required. Install with: sudo apt install jq" >&2
  exit 1
fi

# Read existing daemon.json or start with empty object
if [ -f "${DAEMON_JSON}" ]; then
  current=$(cat "${DAEMON_JSON}")
  echo "→  Existing ${DAEMON_JSON}:"
  echo "${current}" | jq .
else
  current="{}"
  echo "→  No existing ${DAEMON_JSON}, will create one"
fi

# Check if mirror is already configured
if echo "${current}" | jq -e --arg m "${MIRROR}" '."registry-mirrors" // [] | index($m)' >/dev/null; then
  echo "✔  ${MIRROR} is already in registry-mirrors — nothing to do"
  exit 0
fi

# Backup existing config
if [ -f "${DAEMON_JSON}" ]; then
  cp "${DAEMON_JSON}" "${DAEMON_JSON}.bak.$(date +%s)"
  echo "→  Backed up to ${DAEMON_JSON}.bak.$(date +%s)"
fi

# Merge: add mirror to registry-mirrors array (preserve other keys)
updated=$(echo "${current}" | jq --arg m "${MIRROR}" '
  .["registry-mirrors"] = ((.["registry-mirrors"] // []) + [$m] | unique)
')

echo "→  New ${DAEMON_JSON}:"
echo "${updated}" | jq .

echo "${updated}" > "${DAEMON_JSON}"
echo "✔  Wrote ${DAEMON_JSON}"

echo ""
echo "Now restart Docker so the mirror takes effect:"
echo "    sudo systemctl restart docker"
echo ""
echo "Verify:"
echo "    docker info | grep -A2 'Registry Mirrors'"
