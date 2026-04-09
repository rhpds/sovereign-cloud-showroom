#!/bin/bash
# Optional: DataScienceCluster + dashboard when redhat-ods-applications exists.
# Operator pods/service are verified in 01-operator.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-dashboard-host.sh
source "${SCRIPT_DIR}/resolve-dashboard-host.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[AI-CHECK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AI-CHECK]${NC} $1"; }
fail() { echo -e "${RED}[AI-CHECK] FAIL:${NC} $1" >&2; exit 1; }

DSC_CR_NAME="default-dsc"
DSC_NAMESPACE="redhat-ods-applications"

log "========================================================="
log "OpenShift AI — DataScienceCluster / dashboard (optional)"
log "========================================================="
log ""

log "Checking OpenShift CLI..."
if ! oc whoami &>/dev/null; then
  fail "Not logged in. Run: oc login"
fi
log "✓ Connected as $(oc whoami)"

REQUIRED_CONTEXT="local-cluster"
CURRENT_CONTEXT=$(oc config current-context 2>/dev/null || echo "")
if [ "$CURRENT_CONTEXT" != "$REQUIRED_CONTEXT" ]; then
  if ! oc config get-contexts "$REQUIRED_CONTEXT" &>/dev/null; then
    fail "Context '$REQUIRED_CONTEXT' not found"
  fi
  oc config use-context "$REQUIRED_CONTEXT" &>/dev/null || fail "Could not switch to $REQUIRED_CONTEXT"
  log "✓ Using context $REQUIRED_CONTEXT"
else
  log "✓ Context $REQUIRED_CONTEXT"
fi

log ""
if ! oc get namespace "$DSC_NAMESPACE" &>/dev/null; then
  warn "Namespace '$DSC_NAMESPACE' not found — skipping DataScienceCluster and dashboard checks."
  warn "Operator tier is validated in 01-operator.sh (pods + rhods-operator-service)."
  log "✓ Step 2 skipped (no applications namespace yet)"
  exit 0
fi

log "Checking DataScienceCluster $DSC_CR_NAME in $DSC_NAMESPACE..."
if ! oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" &>/dev/null; then
  warn "DataScienceCluster '$DSC_CR_NAME' not found — namespace exists but DSC may not be created yet."
  log "✓ Namespace present; no DSC to verify yet"
  exit 0
fi

DSC_STATUS=$(oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$DSC_STATUS" = "Ready" ]; then
  log "✓ DataScienceCluster phase: Ready"
else
  fail "DataScienceCluster phase is '${DSC_STATUS:-unknown}' (expected Ready). Try: oc describe datasciencecluster $DSC_CR_NAME -n $DSC_NAMESPACE"
fi

log "Checking dashboard route (redhat-ods-applications or openshift-ingress gateway)..."
DASHBOARD_ROUTE=$(ai_resolve_dashboard_host || true)
if [ -z "$DASHBOARD_ROUTE" ]; then
  warn "No dashboard host found. Check: oc get route -n $DSC_NAMESPACE; oc get route -n openshift-ingress | egrep 'rhods-dashboard|data-science-gateway'"
else
  log "✓ Dashboard host: $DASHBOARD_ROUTE"
fi

log ""
log "✓ DataScienceCluster checks passed (Ready)"
log ""
log "Quick status:"
oc get datasciencecluster "$DSC_CR_NAME" -n "$DSC_NAMESPACE" 2>/dev/null || true
log ""
