#!/usr/bin/env bash
#
# OpenShift Pipelines demo setup — applies Tekton Tasks/Pipelines and roxsecrets in pipeline-demo.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[PIPELINES-SETUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[PIPELINES-SETUP]${NC} $*"; }
error() { echo -e "${RED}[PIPELINES-SETUP] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "${BLUE}[PIPELINES-SETUP]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="${SCRIPT_DIR}/openshift-pipelines-setup/manifests"
PIPELINE_NS="${PIPELINE_NAMESPACE:-pipeline-demo}"
RHACS_NS="${RHACS_NAMESPACE:-stackrox}"

export_bashrc_vars() {
  [ ! -f ~/.bashrc ] && return 0
  local var line
  for var in ROX_CENTRAL_ADDRESS ROX_API_TOKEN ROXCTL_CENTRAL_ENDPOINT API_TOKEN RHACS_NAMESPACE; do
    line=$(awk -F= -v v="$var" '$1 ~ "^(export[[:space:]]+)?" v "$" {print; exit}' ~/.bashrc 2>/dev/null || true)
    [ -z "${line}" ] && continue
    if [[ "${line}" =~ \$\(|\` ]]; then
      warn "Skipping ${var} from ~/.bashrc (command substitution detected)."
      continue
    fi
    [[ "${line}" =~ ^export[[:space:]]+ ]] || line="export ${line}"
    eval "${line}" 2>/dev/null || true
  done
}

normalize_central_endpoint() {
  local value="$1"
  value="${value#https://}"
  value="${value#http://}"
  value="${value%%/*}"
  if [[ "${value}" =~ :[0-9]+$ ]]; then
    echo "${value}"
  else
    echo "${value}:443"
  fi
}

resolve_central_endpoint() {
  local host=""
  host=$(oc get route central -n "${RHACS_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "${host}" ]; then
    normalize_central_endpoint "${host}"
    return 0
  fi
  local addr="${ROX_CENTRAL_ADDRESS:-}"
  [ -n "${addr}" ] || return 1
  normalize_central_endpoint "${addr}"
}

apply_rox_secret() {
  local endpoint="$1"
  local token="$2"
  oc -n "${PIPELINE_NS}" create secret generic roxsecrets \
    --from-literal=rox_central_endpoint="${endpoint}" \
    --from-literal=rox_api_token="${token}" \
    --dry-run=client -o yaml | oc apply -f -
}

main() {
  log "Starting OpenShift Pipelines setup"

  command -v oc >/dev/null 2>&1 || error "oc not found"
  command -v python3 >/dev/null 2>&1 || warn "python3 not found (not required for this script)"
  oc whoami >/dev/null 2>&1 || error "OpenShift CLI not connected. Run: oc login"

  [ -d "${MANIFESTS_DIR}" ] || error "Missing manifests directory: ${MANIFESTS_DIR}"

  export_bashrc_vars
  if [ -n "${RHACS_NAMESPACE:-}" ]; then
    RHACS_NS="${RHACS_NAMESPACE}"
  fi

  local rox_token=""
  if [ -n "${API_TOKEN:-}" ]; then
    rox_token="${API_TOKEN}"
  elif [ -n "${ROX_API_TOKEN:-}" ]; then
    rox_token="${ROX_API_TOKEN}"
  fi
  [ -n "${rox_token}" ] || error "API_TOKEN or ROX_API_TOKEN is required for roxsecrets"
  if [ ${#rox_token} -lt 20 ]; then
    error "RHACS token appears invalid (too short)"
  fi

  local endpoint=""
  if [ -n "${ROXCTL_CENTRAL_ENDPOINT:-}" ]; then
    endpoint=$(normalize_central_endpoint "${ROXCTL_CENTRAL_ENDPOINT}")
  else
    endpoint=$(resolve_central_endpoint) || error "Cannot resolve RHACS Central endpoint from route or ROX_CENTRAL_ADDRESS"
  fi

  oc get crd tasks.tekton.dev >/dev/null 2>&1 || error "Tekton Task CRD not found. Install OpenShift Pipelines first."

  step "Applying namespace ${PIPELINE_NS}"
  oc apply -f "${MANIFESTS_DIR}/namespace.yaml"

  step "Applying roxsecrets in ${PIPELINE_NS}"
  apply_rox_secret "${endpoint}" "${rox_token}"

  step "Applying Tekton Tasks"
  oc apply -f "${MANIFESTS_DIR}/tasks/"

  step "Applying Tekton Pipelines"
  oc apply -f "${MANIFESTS_DIR}/pipeline/"

  log "Setup complete in namespace ${PIPELINE_NS}"
  log "Run example: tkn pipeline start rox-log4shell-pipeline -n ${PIPELINE_NS}"
}

main "$@"
