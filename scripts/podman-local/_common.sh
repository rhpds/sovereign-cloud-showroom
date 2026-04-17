# shellcheck shell=bash
# Shared configuration for local Showroom preview (Antora site + Podman httpd).
# Sourced by build.sh, serve.sh, stop.sh, status.sh, up.sh

if [[ -n "${SHOWROOM_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
SHOWROOM_COMMON_LOADED=1

_showroom_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOWROOM_REPO_ROOT="$(cd "${_showroom_script_dir}/../.." && pwd)"

export SHOWROOM_REPO_ROOT
export SHOWROOM_SITE_YML="${SHOWROOM_SITE_YML:-${SHOWROOM_REPO_ROOT}/default-site.yml}"
export SHOWROOM_WWW="${SHOWROOM_WWW:-${SHOWROOM_REPO_ROOT}/www}"
export SHOWROOM_CONTAINER_NAME="${SHOWROOM_CONTAINER_NAME:-showroom-httpd}"
export SHOWROOM_HTTPD_IMAGE="${SHOWROOM_HTTPD_IMAGE:-registry.access.redhat.com/ubi9/httpd-24:1-301}"
export SHOWROOM_PORT="${SHOWROOM_PORT:-8080}"
