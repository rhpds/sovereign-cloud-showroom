#!/usr/bin/env bash
# Stop the Podman httpd container started by serve.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_common.sh"

if podman kill "${SHOWROOM_CONTAINER_NAME}" 2>/dev/null; then
  echo "Stopped ${SHOWROOM_CONTAINER_NAME}."
else
  podman rm -f "${SHOWROOM_CONTAINER_NAME}" 2>/dev/null && echo "Removed ${SHOWROOM_CONTAINER_NAME}." || echo "Container ${SHOWROOM_CONTAINER_NAME} was not running."
fi
