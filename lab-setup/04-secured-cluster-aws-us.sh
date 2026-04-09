#!/bin/bash
# Verify pre-provisioned RHACS:
#   - Central exists only on local-cluster (never on aws-us).
#   - Secured Cluster sensor on local-cluster and on aws-us (if context exists).
# Does not install or generate init bundles.
#
# Env:
#   LOCAL_CLUSTER_CONTEXT   default: local-cluster  (where Central + first sensor live)
#   SECURED_CLUSTER_CONTEXT default: aws-us         (remote sensor only — no Central here)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[RHACS-VERIFY]${NC} $1"; }
warning() { echo -e "${YELLOW}[RHACS-VERIFY]${NC} $1"; }
error() { echo -e "${RED}[RHACS-VERIFY] ERROR:${NC} $1" >&2; exit 1; }

LOCAL_CLUSTER_CONTEXT="${LOCAL_CLUSTER_CONTEXT:-local-cluster}"
SECURED_CLUSTER_CONTEXT="${SECURED_CLUSTER_CONTEXT:-aws-us}"
RHACS_NAMESPACES=(stackrox rhacs-operator)

# Always target the named context — do not rely on the shell's current context (other scripts may leave aws-us).
oc_local() { oc --context="$LOCAL_CLUSTER_CONTEXT" "$@"; }
oc_remote() { oc --context="$SECURED_CLUSTER_CONTEXT" "$@"; }

if ! command -v oc >/dev/null 2>&1; then
    error "oc not found"
fi

context_exists() {
    oc config get-contexts -o name 2>/dev/null | sed 's|^context/||' | grep -qx "$1"
}

deployment_ready() {
    local ctx="$1"
    local ns="$2"
    local name="$3"
    local ready desired
    ready=$(oc --context="$ctx" get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
    desired=$(oc --context="$ctx" get deployment "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
    if [ -z "$desired" ] || [ "$desired" = "0" ]; then
        return 1
    fi
    [ -n "$ready" ] && [ "$ready" = "$desired" ]
}

find_central_namespace() {
    local ctx="$1"
    local ns
    for ns in "${RHACS_NAMESPACES[@]}"; do
        if oc --context="$ctx" get route central -n "$ns" >/dev/null 2>&1; then
            echo "$ns"
            return 0
        fi
    done
    return 1
}

find_sensor_namespace() {
    local ctx="$1"
    local ns
    for ns in "${RHACS_NAMESPACES[@]}"; do
        if oc --context="$ctx" get deployment sensor -n "$ns" >/dev/null 2>&1; then
            echo "$ns"
            return 0
        fi
    done
    return 1
}

log "========================================================="
log "Verifying RHACS Central + Secured Cluster (pre-provisioned env)"
log "========================================================="
log "Central checks use context: $LOCAL_CLUSTER_CONTEXT"
log "Remote Secured Cluster checks use context: $SECURED_CLUSTER_CONTEXT"
log ""

if ! context_exists "$LOCAL_CLUSTER_CONTEXT"; then
    error "Kube context '$LOCAL_CLUSTER_CONTEXT' not found (Central is expected only there). Try: oc config get-contexts"
fi

# --- local-cluster: Central + local Secured Cluster ---
CENTRAL_NS=""
if CENTRAL_NS=$(find_central_namespace "$LOCAL_CLUSTER_CONTEXT"); then
    :
else
    error "No route 'central' in stackrox or rhacs-operator on context $LOCAL_CLUSTER_CONTEXT"
fi

CENTRAL_HOST=$(oc_local get route central -n "$CENTRAL_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
[ -n "$CENTRAL_HOST" ] || error "Could not read Central route host in namespace $CENTRAL_NS on $LOCAL_CLUSTER_CONTEXT"

log "✓ Central route on $LOCAL_CLUSTER_CONTEXT: namespace=$CENTRAL_NS host=$CENTRAL_HOST"

if oc_local get deployment central -n "$CENTRAL_NS" >/dev/null 2>&1; then
    if deployment_ready "$LOCAL_CLUSTER_CONTEXT" "$CENTRAL_NS" central; then
        log "✓ Deployment central is Available (ready=replicas) in $CENTRAL_NS on $LOCAL_CLUSTER_CONTEXT"
    else
        error "Deployment central in $CENTRAL_NS is not fully ready on $LOCAL_CLUSTER_CONTEXT: oc --context $LOCAL_CLUSTER_CONTEXT get deploy central -n $CENTRAL_NS"
    fi
else
    error "Deployment central not found in $CENTRAL_NS on $LOCAL_CLUSTER_CONTEXT (Central is not on $SECURED_CLUSTER_CONTEXT)"
fi

SENSOR_NS_LOCAL=""
if SENSOR_NS_LOCAL=$(find_sensor_namespace "$LOCAL_CLUSTER_CONTEXT"); then
    if deployment_ready "$LOCAL_CLUSTER_CONTEXT" "$SENSOR_NS_LOCAL" sensor; then
        log "✓ Secured Cluster sensor on $LOCAL_CLUSTER_CONTEXT: deployment/sensor ready in $SENSOR_NS_LOCAL"
    else
        error "Deployment sensor in $SENSOR_NS_LOCAL is not fully ready on $LOCAL_CLUSTER_CONTEXT: oc --context $LOCAL_CLUSTER_CONTEXT get deploy sensor -n $SENSOR_NS_LOCAL"
    fi
else
    error "No deployment sensor in stackrox or rhacs-operator on $LOCAL_CLUSTER_CONTEXT"
fi

if oc_local get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
    if oc_local get securedcluster.platform.stackrox.io -A -o name 2>/dev/null | grep -q .; then
        log "✓ SecuredCluster CR(s) on $LOCAL_CLUSTER_CONTEXT:"
        oc_local get securedcluster.platform.stackrox.io -A 2>/dev/null || true
    else
        warning "No SecuredCluster CR listed on $LOCAL_CLUSTER_CONTEXT (sensor still verified above)"
    fi
fi

# --- aws-us: Secured Cluster only (no Central) ---
if ! context_exists "$SECURED_CLUSTER_CONTEXT"; then
    warning "No '$SECURED_CLUSTER_CONTEXT' context in kubeconfig — skipping remote Secured Cluster checks"
    log "========================================================="
    log "RHACS verification complete ($LOCAL_CLUSTER_CONTEXT only)"
    log "========================================================="
    exit 0
fi

SENSOR_NS_REMOTE=""
if SENSOR_NS_REMOTE=$(find_sensor_namespace "$SECURED_CLUSTER_CONTEXT"); then
    if deployment_ready "$SECURED_CLUSTER_CONTEXT" "$SENSOR_NS_REMOTE" sensor; then
        log "✓ Secured Cluster sensor on $SECURED_CLUSTER_CONTEXT: deployment/sensor ready in $SENSOR_NS_REMOTE"
    else
        error "Deployment sensor in $SENSOR_NS_REMOTE on $SECURED_CLUSTER_CONTEXT is not fully ready: oc --context $SECURED_CLUSTER_CONTEXT get deploy sensor -n $SENSOR_NS_REMOTE"
    fi
else
    error "No deployment sensor in stackrox or rhacs-operator on context $SECURED_CLUSTER_CONTEXT"
fi

if oc_remote get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
    if oc_remote get securedcluster.platform.stackrox.io -A -o name 2>/dev/null | grep -q .; then
        log "✓ SecuredCluster CR(s) on $SECURED_CLUSTER_CONTEXT:"
        oc_remote get securedcluster.platform.stackrox.io -A 2>/dev/null || true
    else
        warning "No SecuredCluster CR listed on $SECURED_CLUSTER_CONTEXT (sensor deployment verified)"
    fi
fi

oc config use-context "$LOCAL_CLUSTER_CONTEXT" >/dev/null 2>&1 || true

log "========================================================="
log "RHACS verification complete: Central + sensor on $LOCAL_CLUSTER_CONTEXT; sensor on $SECURED_CLUSTER_CONTEXT"
log "========================================================="
