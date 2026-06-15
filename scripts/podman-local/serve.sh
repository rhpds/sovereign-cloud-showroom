#!/usr/bin/env bash
# Serve ./www with Apache httpd in Podman (same image as the repo Makefile).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_common.sh"

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: podman not found in PATH." >&2
  exit 1
fi

cd "${SHOWROOM_REPO_ROOT}"
mkdir -p www

if [[ ! -f www/index.html ]] && [[ -z "$(find www -type f 2>/dev/null | head -1)" ]]; then
  echo "WARNING: www/ looks empty. Run ${SCRIPT_DIR}/build.sh first." >&2
fi

if [[ -n "${SHOWROOM_PULL:-}" ]]; then
  echo "Pulling ${SHOWROOM_HTTPD_IMAGE}..."
  podman pull "${SHOWROOM_HTTPD_IMAGE}"
fi

echo "Stopping any existing container named ${SHOWROOM_CONTAINER_NAME}..."
podman rm -f "${SHOWROOM_CONTAINER_NAME}" 2>/dev/null || true

echo "Starting httpd on port ${SHOWROOM_PORT}..."
podman run -d --rm --name "${SHOWROOM_CONTAINER_NAME}" \
  -p "${SHOWROOM_PORT}:8080" \
  -v "${SHOWROOM_WWW}:/var/www/html/:z" \
  "${SHOWROOM_HTTPD_IMAGE}"

echo "Open http://localhost:${SHOWROOM_PORT}/index.html"
echo "Stop with: ${SCRIPT_DIR}/stop.sh"
