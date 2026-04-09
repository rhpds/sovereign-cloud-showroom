#!/bin/bash
# Verify Red Hat OpenShift AI operator is installed (no changes to the cluster).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[AI-CHECK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AI-CHECK]${NC} $1"; }
fail() { echo -e "${RED}[AI-CHECK] FAIL:${NC} $1" >&2; exit 1; }

log "========================================================="
log "OpenShift AI — operator verification"
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

OPERATOR_NAMESPACE="redhat-ods-operator"
OPERATOR_PACKAGE="rhods-operator"

log ""
log "Checking namespace $OPERATOR_NAMESPACE..."
oc get namespace "$OPERATOR_NAMESPACE" &>/dev/null || fail "Namespace '$OPERATOR_NAMESPACE' not found"

log "Checking Subscription $OPERATOR_PACKAGE..."
oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" &>/dev/null \
  || fail "Subscription '$OPERATOR_PACKAGE' not found in $OPERATOR_NAMESPACE"

CURRENT_CSV=$(oc get subscription.operators.coreos.com "$OPERATOR_PACKAGE" -n "$OPERATOR_NAMESPACE" \
  -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
[ -n "$CURRENT_CSV" ] && [ "$CURRENT_CSV" != "null" ] || fail "Subscription has no currentCSV yet"

log "Checking CSV $CURRENT_CSV..."
oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" &>/dev/null || fail "CSV '$CURRENT_CSV' not found"
CSV_PHASE=$(oc get csv "$CURRENT_CSV" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
[ "$CSV_PHASE" = "Succeeded" ] || fail "CSV phase is '$CSV_PHASE' (expected Succeeded)"

OG_COUNT=$(oc get operatorgroup -n "$OPERATOR_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "${OG_COUNT:-0}" -ge 1 ] || warn "No OperatorGroup in $OPERATOR_NAMESPACE (unexpected for OLM)"

RHODS_SVC="${RHODS_OPERATOR_SERVICE:-rhods-operator-service}"
log "Checking Service $RHODS_SVC..."
oc get "svc/$RHODS_SVC" -n "$OPERATOR_NAMESPACE" &>/dev/null \
  || fail "Service '$RHODS_SVC' not found in $OPERATOR_NAMESPACE (see: oc get svc -n $OPERATOR_NAMESPACE)"

log "Checking operator Pods (Running)..."
# READY column can be "1/1"; STATUS is column 3 in default oc get pods output
RUNNING_COUNT=$(oc get pods -n "$OPERATOR_NAMESPACE" --no-headers 2>/dev/null | awk '$3 == "Running" { n++ } END { print n+0 }')
[ "${RUNNING_COUNT:-0}" -ge 1 ] \
  || fail "No Running pods in $OPERATOR_NAMESPACE — try: oc get pods -n $OPERATOR_NAMESPACE"

log ""
log "✓ OpenShift AI operator checks passed"
log "  CSV: $CURRENT_CSV ($CSV_PHASE)"
log "  Service: $RHODS_SVC"
log "  Running pods in $OPERATOR_NAMESPACE: $RUNNING_COUNT"
log ""
