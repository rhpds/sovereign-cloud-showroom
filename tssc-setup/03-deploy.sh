#!/bin/bash

# Script to deploy Red Hat Trusted Artifact Signer (RHTAS) components
# Assumes oc is installed and user is logged in as cluster-admin
# Assumes RHTAS Operator is installed and Keycloak is configured
# Usage: ./03-deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBE_CONTEXT="${KUBE_CONTEXT:-local-cluster}"
oc config use-context "$KUBE_CONTEXT" &>/dev/null || true

# Resolve Keycloak namespace from workloads / CRs / operator CSV — not from OLM Subscription objects.
discover_keycloak_namespace() {
    local ns _csv_line _routes_out line _r_ns _r_name
    if [ -n "${KEYCLOAK_NAMESPACE_OVERRIDE:-}" ] && oc get namespace "${KEYCLOAK_NAMESPACE_OVERRIDE}" >/dev/null 2>&1; then
        echo "${KEYCLOAK_NAMESPACE_OVERRIDE}"
        return 0
    fi
    if [ -n "${KEYCLOAK_NAMESPACE:-}" ] && oc get namespace "${KEYCLOAK_NAMESPACE}" >/dev/null 2>&1; then
        echo "${KEYCLOAK_NAMESPACE}"
        return 0
    fi
    ns=$(oc get keycloaks.k8s.keycloak.org -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    [ -n "$ns" ] && echo "$ns" && return 0
    ns=$(oc get deployment -A -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    [ -n "$ns" ] && echo "$ns" && return 0
    ns=$(oc get pods -A -l app.kubernetes.io/name=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    [ -n "$ns" ] && echo "$ns" && return 0
    _csv_line=$(oc get csv -A --no-headers 2>/dev/null | grep -iE 'keycloak|rhbk' | head -1 || true)
    if [ -n "$_csv_line" ]; then
        ns=$(echo "$_csv_line" | awk '{print $1}')
        [ -n "$ns" ] && echo "$ns" && return 0
    fi
    if oc get namespace rhsso >/dev/null 2>&1; then
        echo "rhsso"
        return 0
    fi
    if oc get namespace keycloak >/dev/null 2>&1; then
        echo "keycloak"
        return 0
    fi
    _routes_out=$(oc get routes -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        _r_ns="${line%% *}"
        _r_name="${line#* }"
        if [ "$_r_name" = "keycloak-rhsso" ] || [ "$_r_name" = "keycloak" ]; then
            echo "$_r_ns"
            return 0
        fi
    done <<< "$_routes_out"
    return 1
}

# RHBK / Keycloak Quarkus: https://HOST/realms/REALM — legacy RH-SSO: https://HOST/auth/realms/REALM
discover_keycloak_oidc_issuer_url() {
    local host=$1
    local realm=${2:-openshift}
    local base="https://${host}"
    local disco_mod="${base}/realms/${realm}/.well-known/openid-configuration"
    local disco_legacy="${base}/auth/realms/${realm}/.well-known/openid-configuration"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --connect-timeout 5 --max-time 15 "$disco_mod" 2>/dev/null | grep -q '"issuer"'; then
            echo "${base}/realms/${realm}"
            return 0
        fi
        if curl -fsS --connect-timeout 5 --max-time 15 "$disco_legacy" 2>/dev/null | grep -q '"issuer"'; then
            echo "${base}/auth/realms/${realm}"
            return 0
        fi
    fi
    if oc get keycloaks.k8s.keycloak.org -A --no-headers 2>/dev/null | grep -q .; then
        echo "${base}/realms/${realm}"
        return 0
    fi
    if oc get keycloak.k8s.keycloak.org -A --no-headers 2>/dev/null | grep -q .; then
        echo "${base}/realms/${realm}"
        return 0
    fi
    echo "${base}/auth/realms/${realm}"
    return 0
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHTAS-DEPLOY]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHTAS-DEPLOY]${NC} $1"
}

error() {
    echo -e "${RED}[RHTAS-DEPLOY] ERROR:${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${BLUE}[RHTAS-DEPLOY]${NC} $1"
}

# Securesign / stack namespace (some clusters also run the controller manager here instead of only openshift-operators)
RHTAS_TARGET_NAMESPACE="${RHTAS_TARGET_NAMESPACE:-trusted-artifact-signer}"

# Count RHTAS *operator controller* pods: OLM default label in openshift-operators or same label in the target namespace.
rhtas_operator_labeled_pods() {
    local ns=$1
    oc get pods -n "$ns" -l name=trusted-artifact-signer-operator --no-headers 2>/dev/null | wc -l | tr -d ' '
}

# Fallback when label does not match (e.g. controller or client-server components in the stack namespace)
rhtas_controller_pods_fallback() {
    local ns=$1
    oc get pods -n "$ns" --no-headers 2>/dev/null | grep -iE 'trusted-artifact-signer.*(operator|controller)|rhtas.*(operator|controller)|controller-manager|^cli-server-' | wc -l | tr -d ' '
}

# First namespace (among openshift-operators and target ns) that has any operator/controller signal; prints ns name or empty
rhtas_operator_namespace_detect() {
    local ns c
    for ns in openshift-operators "$RHTAS_TARGET_NAMESPACE"; do
        oc get namespace "$ns" &>/dev/null || continue
        c=$(rhtas_operator_labeled_pods "$ns")
        [ "${c:-0}" -gt 0 ] && echo "$ns" && return 0
        c=$(rhtas_controller_pods_fallback "$ns")
        [ "${c:-0}" -gt 0 ] && echo "$ns" && return 0
    done
    echo ""
}

log "========================================================="
log "Red Hat Trusted Artifact Signer Component Deployment"
log "========================================================="
log ""

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami >/dev/null 2>&1; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if RHTAS Operator is installed and ready
log "Checking if RHTAS Operator is installed and ready..."

# Find CSV
CSV_NAME=$(oc get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName=="Trusted Artifact Signer Operator")].metadata.name}' 2>/dev/null || echo "")
if [ -z "$CSV_NAME" ]; then
    CSV_NAME=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep -i "trusted-artifact-signer\|rhtas" | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
fi

if [ -z "$CSV_NAME" ]; then
    error "RHTAS Operator CSV not found. Please install it first by running: ./02-operator.sh"
fi

# Check CSV phase
CSV_PHASE=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$CSV_PHASE" != "Succeeded" ]; then
    warning "RHTAS Operator CSV is not in Succeeded phase. Current phase: ${CSV_PHASE:-Unknown}"
    warning "The operator may not be fully installed. Continuing anyway..."
else
    log "✓ RHTAS Operator CSV is in Succeeded phase"
fi

# Check if CRDs are installed
log "Checking if RHTAS CRDs are installed..."
REQUIRED_CRDS=(
    "securesigns.rhtas.redhat.com"
    "tufs.rhtas.redhat.com"
    "fulcios.rhtas.redhat.com"
    "rekors.rhtas.redhat.com"
)

MISSING_CRDS=""
for crd in "${REQUIRED_CRDS[@]}"; do
    if ! oc get crd "$crd" >/dev/null 2>&1; then
        MISSING_CRDS="${MISSING_CRDS} ${crd}"
    fi
done

if [ -n "$MISSING_CRDS" ]; then
    error "Required RHTAS CRDs are missing:${MISSING_CRDS}"
    error "Please ensure the operator is fully installed by running: ./02-operator.sh"
fi
log "✓ All required CRDs are installed"

# Check if operator/controller pods are running (OLM uses openshift-operators; some installs also show controllers in the stack namespace)
OPERATOR_NS=$(rhtas_operator_namespace_detect)
if [ -z "$OPERATOR_NS" ]; then
    warning "No RHTAS operator/controller pods found in openshift-operators or ${RHTAS_TARGET_NAMESPACE} (label name=trusted-artifact-signer-operator, or controller name pattern)."
    warning "The operator may not be functioning correctly. Continuing anyway..."
else
    READY_PODS=$(oc get pods -n "$OPERATOR_NS" -l name=trusted-artifact-signer-operator --field-selector=status.phase=Running -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
    if [ "${READY_PODS:-0}" -gt 0 ]; then
        log "✓ RHTAS operator pods are running and ready in namespace ${OPERATOR_NS} (${READY_PODS} pod(s))"
    else
        log "✓ RHTAS operator/controller activity detected in namespace ${OPERATOR_NS}"
    fi
fi

# Check if Keycloak is available (RH-SSO / rhsso, Red Hat build of Keycloak / keycloak, or override)
log "Checking if Keycloak is available..."
KEYCLOAK_NAMESPACE=""
if ! KEYCLOAK_NAMESPACE=$(discover_keycloak_namespace); then
    KEYCLOAK_NAMESPACE=""
fi
if [ -z "$KEYCLOAK_NAMESPACE" ]; then
    error "Keycloak namespace not found (workloads, keycloaks.k8s.keycloak.org CR, operator CSV in openshift-operators, or namespaces rhsso/keycloak). Install Keycloak or set KEYCLOAK_NAMESPACE_OVERRIDE."
fi

KEYCLOAK_ROUTE=""
for _rt in keycloak keycloak-rhsso rhbk-keycloak; do
    KEYCLOAK_ROUTE=$(oc get route "$_rt" -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    [ -n "$KEYCLOAK_ROUTE" ] && break
done
if [ -z "$KEYCLOAK_ROUTE" ]; then
    KEYCLOAK_ROUTE=$(oc get routes -n "$KEYCLOAK_NAMESPACE" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -m1 '[[:alnum:]]' || true)
fi
if [ -z "$KEYCLOAK_ROUTE" ]; then
    error "Keycloak route not found. Please ensure Keycloak is installed and running."
fi
log "✓ Keycloak is available at: https://${KEYCLOAK_ROUTE}"

# Get OIDC configuration (issuer path differs: Quarkus /realms/ vs legacy /auth/realms/)
if [ -n "${OIDC_ISSUER_URL:-}" ]; then
    log "✓ Using OIDC_ISSUER_URL from environment: ${OIDC_ISSUER_URL}"
else
    OIDC_ISSUER_URL=$(discover_keycloak_oidc_issuer_url "$KEYCLOAK_ROUTE" openshift)
    log "✓ OIDC Issuer URL (auto-detected): ${OIDC_ISSUER_URL}"
fi
OIDC_CLIENT_ID="trusted-artifact-signer"
log "✓ OIDC Client ID: ${OIDC_CLIENT_ID}"

log "Prerequisites validated successfully"
log ""

# API version is confirmed from CRDs
RHTAS_API_VERSION="rhtas.redhat.com/v1alpha1"
log "Using API version: ${RHTAS_API_VERSION}"
log ""

# Step 1: Create namespace
RHTAS_NAMESPACE="${RHTAS_TARGET_NAMESPACE}"
log "Step 1: Creating namespace '${RHTAS_NAMESPACE}'..."

if oc get namespace $RHTAS_NAMESPACE >/dev/null 2>&1; then
    log "✓ Namespace '${RHTAS_NAMESPACE}' already exists"
else
    if ! oc create namespace $RHTAS_NAMESPACE; then
        error "Failed to create namespace '${RHTAS_NAMESPACE}'"
    fi
    log "✓ Namespace created successfully"
fi

# Step 2: Deploy Securesign CR (manages TUF, Fulcio, and Rekor)
log ""
log "Step 2: Deploying RHTAS components..."

# Check if Securesign CRD exists
SECURESIGN_CRD_EXISTS=false
if oc get crd securesigns.rhtas.redhat.com >/dev/null 2>&1; then
    SECURESIGN_CRD_EXISTS=true
    log "Securesign CRD found - using Securesign CR to manage components"
    
    SECURESIGN_NAME="securesign"
    if oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        log "✓ Securesign CR '${SECURESIGN_NAME}' already exists"
    else
        log "Creating Securesign CR..."
        if ! cat <<EOF | oc apply -f -
apiVersion: ${RHTAS_API_VERSION}
kind: Securesign
metadata:
  name: ${SECURESIGN_NAME}
  namespace: ${RHTAS_NAMESPACE}
spec:
  fulcio:
    certificate:
      commonName: fulcio.hostname
      organizationEmail: admin@demo.redhat.com
      organizationName: Red Hat
    config:
      OIDCIssuers:
        - ClientID: ${OIDC_CLIENT_ID}
          Issuer: ${OIDC_ISSUER_URL}
          IssuerURL: ${OIDC_ISSUER_URL}
          Type: email
    ctlog:
      port: 80
      prefix: trusted-artifact-signer
    externalAccess:
      enabled: true
    monitoring:
      enabled: false
  rekor:
    externalAccess:
      enabled: true
    monitoring:
      enabled: false
    pvc:
      accessModes:
        - ReadWriteOnce
      retain: true
      size: 5Gi
    rekorSearchUI:
      enabled: true
    sharding: []
    signer:
      kms: secret
    trillian:
      port: 8091
    backFillRedis:
      enabled: true
      schedule: 0 0 * * *
  trillian:
    database:
      create: true
      pvc:
        accessModes:
          - ReadWriteOnce
        retain: true
        size: 5Gi
      tls: {}
    monitoring:
      enabled: false
  ctlog:
    monitoring:
      enabled: false
    trillian:
      port: 8091
  tuf:
    externalAccess:
      enabled: true
    keys:
      - name: rekor.pub
      - name: ctfe.pub
      - name: fulcio_v1.crt.pem
    port: 80
    pvc:
      accessModes:
        - ReadWriteOnce
      retain: true
      size: 100Mi
    rootKeySecretRef:
      name: tuf-root-keys
EOF
        then
            error "Failed to create Securesign CR. Check if the API version is correct: ${RHTAS_API_VERSION}"
        fi
        log "✓ Securesign CR created successfully"
    fi
else
    log "Securesign CRD not found - creating individual component CRs"
    SECURESIGN_NAME=""
    
    # Create TUF CR
    log "Creating TUF CR..."
    TUF_NAME="tuf"
    if oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        log "✓ TUF CR '${TUF_NAME}' already exists"
    else
        if ! cat <<EOF | oc apply -f -
apiVersion: ${RHTAS_API_VERSION}
kind: Tuf
metadata:
  name: ${TUF_NAME}
  namespace: ${RHTAS_NAMESPACE}
spec:
  externalAccess:
    enabled: true
  keys:
    - name: rekor.pub
    - name: ctfe.pub
    - name: fulcio_v1.crt.pem
  pvc:
    accessModes:
      - ReadWriteOnce
    retain: true
    size: 100Mi
EOF
        then
            error "Failed to create TUF CR"
        fi
        log "✓ TUF CR created successfully"
    fi
    
    # Create Fulcio CR
    log "Creating Fulcio CR with Keycloak OIDC..."
    FULCIO_NAME="fulcio-server"
    if oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        log "✓ Fulcio CR '${FULCIO_NAME}' already exists"
    else
        if ! cat <<EOF | oc apply -f -
apiVersion: ${RHTAS_API_VERSION}
kind: Fulcio
metadata:
  name: ${FULCIO_NAME}
  namespace: ${RHTAS_NAMESPACE}
spec:
  externalAccess:
    enabled: true
  oidc:
    issuer: ${OIDC_ISSUER_URL}
    clientID: ${OIDC_CLIENT_ID}
EOF
        then
            error "Failed to create Fulcio CR"
        fi
        log "✓ Fulcio CR created successfully"
    fi
    
    # Create Rekor CR
    log "Creating Rekor CR..."
    REKOR_NAME="rekor-server"
    if oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
        log "✓ Rekor CR '${REKOR_NAME}' already exists"
    else
        if ! cat <<EOF | oc apply -f -
apiVersion: ${RHTAS_API_VERSION}
kind: Rekor
metadata:
  name: ${REKOR_NAME}
  namespace: ${RHTAS_NAMESPACE}
spec:
  externalAccess:
    enabled: true
EOF
        then
            error "Failed to create Rekor CR"
        fi
        log "✓ Rekor CR created successfully"
    fi
fi

# Diagnostic check: Verify operator is running and CRs are being reconciled
log ""
log "Checking operator status and CR reconciliation..."

# Operator/controller pods: prefer openshift-operators, then trusted-artifact-signer (same checks as prerequisites above)
OPERATOR_DIAG_NS=$(rhtas_operator_namespace_detect)
if [ -z "$OPERATOR_DIAG_NS" ]; then
    warning "No RHTAS operator/controller pods found in openshift-operators or ${RHTAS_TARGET_NAMESPACE}"
    log "Checking cluster-wide for label name=trusted-artifact-signer-operator..."
    OPERATOR_PODS_ALL=$(oc get pods -A -l name=trusted-artifact-signer-operator --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${OPERATOR_PODS_ALL:-0}" -eq 0 ]; then
        warning "Still not found. Verify CSV: oc get csv -n openshift-operators | grep -i trusted-artifact-signer"
        log "Or workloads in stack namespace: oc get pods -n ${RHTAS_TARGET_NAMESPACE}"
    else
        log "Found operator pods elsewhere in the cluster (${OPERATOR_PODS_ALL} pod(s) with expected label)"
    fi
else
    OPERATOR_POD_STATUS=$(oc get pods -n "$OPERATOR_DIAG_NS" -l name=trusted-artifact-signer-operator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    OPERATOR_POD_READY=$(oc get pods -n "$OPERATOR_DIAG_NS" -l name=trusted-artifact-signer-operator -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "")
    if [ "$OPERATOR_POD_STATUS" = "Running" ] && [ "$OPERATOR_POD_READY" = "true" ]; then
        log "✓ Operator pod is running and ready (namespace ${OPERATOR_DIAG_NS})"
    elif [ -n "$OPERATOR_POD_STATUS" ] || [ -n "$OPERATOR_POD_READY" ]; then
        warning "Operator pod status in ${OPERATOR_DIAG_NS}: phase=${OPERATOR_POD_STATUS:-Unknown}, ready=${OPERATOR_POD_READY:-Unknown}"
        log "Check operator logs: oc logs -n ${OPERATOR_DIAG_NS} -l name=trusted-artifact-signer-operator --tail=50"
    else
        log "✓ RHTAS controller/operator activity in namespace ${OPERATOR_DIAG_NS} (see also: oc get pods -n ${OPERATOR_DIAG_NS})"
    fi
fi

# Check CR status and events
if [ -n "$SECURESIGN_NAME" ]; then
    log "Checking Securesign CR status..."
    SECURESIGN_STATUS=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    SECURESIGN_CONDITIONS=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
    if [ -n "$SECURESIGN_STATUS" ]; then
        log "  Securesign phase: ${SECURESIGN_STATUS}"
    fi
    if [ -n "$SECURESIGN_CONDITIONS" ]; then
        log "  Conditions: ${SECURESIGN_CONDITIONS}"
        # *Available conditions use status=False while work is in progress (reason Creating, etc.) — not necessarily errors.
        PENDING_CONDITIONS=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.status=="False")].type}' 2>/dev/null || echo "")
        if [ -n "$PENDING_CONDITIONS" ]; then
            info "  Securesign conditions still False (reconciling until True): ${PENDING_CONDITIONS}"
            for cond in $PENDING_CONDITIONS; do
                COND_MSG=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath="{.status.conditions[?(@.type==\"$cond\")].message}" 2>/dev/null || echo "")
                COND_REASON=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath="{.status.conditions[?(@.type==\"$cond\")].reason}" 2>/dev/null || echo "")
                case "${COND_REASON:-}" in
                    Creating|Progressing|Installing|"")
                        info "    $cond: ${COND_REASON:-Unknown} - ${COND_MSG:-No message}"
                        ;;
                    *)
                        warning "    $cond: ${COND_REASON} - ${COND_MSG:-No message}"
                        ;;
                esac
            done
        fi
    else
        info "  No status conditions found yet (CR may still be initializing)"
    fi
    
    # Check for recent events
    log "Checking recent events for ${SECURESIGN_NAME}..."
    RECENT_EVENTS=$(oc get events -n $RHTAS_NAMESPACE --field-selector involvedObject.name=$SECURESIGN_NAME --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5 || echo "")
    if [ -n "$RECENT_EVENTS" ]; then
        info "  Recent events:"
        echo "$RECENT_EVENTS" | while read -r line; do
            info "    $line"
        done
    else
        info "  No recent events found"
    fi
else
    # Check individual CRs
    log "Checking individual CR statuses..."
    for cr_type in tuf fulcio rekor; do
        cr_name_var="${cr_type^^}_NAME"
        eval "cr_name=\$${cr_name_var}"
        if [ -n "$cr_name" ] && oc get ${cr_type}s $cr_name -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
            cr_status=$(oc get ${cr_type}s $cr_name -n $RHTAS_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            cr_ready=$(oc get ${cr_type}s $cr_name -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ -n "$cr_status" ] || [ -n "$cr_ready" ]; then
                log "  ${cr_type^} ($cr_name): Phase=${cr_status:-Unknown}, Ready=${cr_ready:-Unknown}"
            fi
            
            error_msg=$(oc get ${cr_type}s $cr_name -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.status=="False")].message}' 2>/dev/null || echo "")
            error_reason=$(oc get ${cr_type}s $cr_name -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.status=="False")].reason}' 2>/dev/null || echo "")
            if [ -n "$error_msg" ] || [ -n "$error_reason" ]; then
                case "${error_reason:-}" in
                    Creating|Progressing|Installing|"")
                        info "    ${cr_type^} (not ready yet): ${error_reason:-Unknown} - ${error_msg:-No message}"
                        ;;
                    *)
                        warning "    ${cr_type^} error: ${error_reason} - ${error_msg:-No message}"
                        ;;
                esac
            fi
        fi
    done
fi

# Check for any pods in the namespace
log "Checking for pods in ${RHTAS_NAMESPACE} namespace..."
EXISTING_PODS=$(oc get pods -n $RHTAS_NAMESPACE --no-headers 2>/dev/null | wc -l || echo "0")
if [ "$EXISTING_PODS" -gt 0 ]; then
    log "  Found $EXISTING_PODS pod(s) in namespace:"
    oc get pods -n $RHTAS_NAMESPACE --no-headers 2>/dev/null | while read -r line; do
        info "    $line"
    done
else
    info "  No pods found in namespace yet"
fi

log ""

# Wait for components to be ready
log "Waiting for RHTAS components to be ready..."

MAX_WAIT=600
WAIT_COUNT=0
TUF_READY=false
FULCIO_READY=false
REKOR_READY=false

# Initialize component names if not set (for individual CR creation path)
if [ -z "${TUF_NAME:-}" ]; then
    TUF_NAME=""
fi
if [ -z "${FULCIO_NAME:-}" ]; then
    FULCIO_NAME=""
fi
if [ -z "${REKOR_NAME:-}" ]; then
    REKOR_NAME=""
fi

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if [ -n "$SECURESIGN_NAME" ]; then
        # Check Securesign CR status (components are managed by Securesign)
        # Check TUF
        TUF_CONDITION=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="TufAvailable")].status}' 2>/dev/null || echo "")
        if [ "$TUF_CONDITION" = "True" ]; then
            if [ "$TUF_READY" = false ]; then
                TUF_URL=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.tuf.url}' 2>/dev/null || echo "")
                log "✓ TUF is ready at: ${TUF_URL}"
                TUF_READY=true
            fi
        fi
        
        # Check Fulcio
        FULCIO_CONDITION=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="FulcioAvailable")].status}' 2>/dev/null || echo "")
        if [ "$FULCIO_CONDITION" = "True" ]; then
            if [ "$FULCIO_READY" = false ]; then
                FULCIO_URL=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.fulcio.url}' 2>/dev/null || echo "")
                log "✓ Fulcio is ready at: ${FULCIO_URL}"
                FULCIO_READY=true
            fi
        fi
        
        # Check Rekor
        REKOR_CONDITION=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="RekorAvailable")].status}' 2>/dev/null || echo "")
        if [ "$REKOR_CONDITION" = "True" ]; then
            if [ "$REKOR_READY" = false ]; then
                REKOR_URL=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.rekor.url}' 2>/dev/null || echo "")
                log "✓ Rekor is ready at: ${REKOR_URL}"
                REKOR_READY=true
            fi
        fi
    else
        # Check individual component CRs (fallback path)
        # Check TUF status
        if [ -z "$TUF_NAME" ]; then
            TUF_NAME=$(oc get tufs -n $RHTAS_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "tuf")
        fi
        
        if [ -n "$TUF_NAME" ] && oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
            TUF_CONDITION=$(oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ "$TUF_CONDITION" = "True" ]; then
                if [ "$TUF_READY" = false ]; then
                    TUF_URL=$(oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
                    log "✓ TUF is ready at: ${TUF_URL}"
                    TUF_READY=true
                fi
            fi
        fi
        
        # Check Fulcio status
        if [ -z "$FULCIO_NAME" ]; then
            FULCIO_NAME=$(oc get fulcios -n $RHTAS_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "fulcio-server")
        fi
        
        if [ -n "$FULCIO_NAME" ] && oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
            FULCIO_CONDITION=$(oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ "$FULCIO_CONDITION" = "True" ]; then
                if [ "$FULCIO_READY" = false ]; then
                    FULCIO_URL=$(oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
                    log "✓ Fulcio is ready at: ${FULCIO_URL}"
                    FULCIO_READY=true
                fi
            fi
        fi
        
        # Check Rekor status
        if [ -z "$REKOR_NAME" ]; then
            REKOR_NAME=$(oc get rekors -n $RHTAS_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "rekor-server")
        fi
        
        if [ -n "$REKOR_NAME" ] && oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
            REKOR_CONDITION=$(oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ "$REKOR_CONDITION" = "True" ]; then
                if [ "$REKOR_READY" = false ]; then
                    REKOR_URL=$(oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
                    log "✓ Rekor is ready at: ${REKOR_URL}"
                    REKOR_READY=true
                fi
            fi
        fi
    fi
    
    # If all are ready, break
    if [ "$TUF_READY" = true ] && [ "$FULCIO_READY" = true ] && [ "$REKOR_READY" = true ]; then
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Progress (${WAIT_COUNT}s/${MAX_WAIT}s):"
        log "    TUF: ${TUF_READY:-false}"
        log "    Fulcio: ${FULCIO_READY:-false}"
        log "    Rekor: ${REKOR_READY:-false}"
        
        # Show diagnostic information for components that aren't ready
        if [ "$TUF_READY" = false ]; then
            if [ -n "$SECURESIGN_NAME" ]; then
                TUF_CONDITION_MSG=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="TufAvailable")].message}' 2>/dev/null || echo "")
                TUF_CONDITION_REASON=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="TufAvailable")].reason}' 2>/dev/null || echo "")
                if [ -n "$TUF_CONDITION_MSG" ] || [ -n "$TUF_CONDITION_REASON" ]; then
                    info "    TUF Status: ${TUF_CONDITION_REASON:-Unknown} - ${TUF_CONDITION_MSG:-No message}"
                fi
            elif [ -n "$TUF_NAME" ] && oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
                TUF_CONDITION_MSG=$(oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
                TUF_CONDITION_REASON=$(oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
                if [ -n "$TUF_CONDITION_MSG" ] || [ -n "$TUF_CONDITION_REASON" ]; then
                    info "    TUF Status: ${TUF_CONDITION_REASON:-Unknown} - ${TUF_CONDITION_MSG:-No message}"
                fi
                # Check for TUF pods
                TUF_PODS=$(oc get pods -n $RHTAS_NAMESPACE -l app=tuf --no-headers 2>/dev/null | wc -l || echo "0")
                if [ "$TUF_PODS" -gt 0 ]; then
                    TUF_POD_STATUS=$(oc get pods -n $RHTAS_NAMESPACE -l app=tuf -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
                    info "    TUF Pods: $TUF_PODS pod(s), Status: ${TUF_POD_STATUS:-Unknown}"
                fi
            fi
        fi
        
        if [ "$FULCIO_READY" = false ]; then
            if [ -n "$SECURESIGN_NAME" ]; then
                FULCIO_CONDITION_MSG=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="FulcioAvailable")].message}' 2>/dev/null || echo "")
                FULCIO_CONDITION_REASON=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="FulcioAvailable")].reason}' 2>/dev/null || echo "")
                if [ -n "$FULCIO_CONDITION_MSG" ] || [ -n "$FULCIO_CONDITION_REASON" ]; then
                    info "    Fulcio Status: ${FULCIO_CONDITION_REASON:-Unknown} - ${FULCIO_CONDITION_MSG:-No message}"
                fi
            elif [ -n "$FULCIO_NAME" ] && oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
                FULCIO_CONDITION_MSG=$(oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
                FULCIO_CONDITION_REASON=$(oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
                if [ -n "$FULCIO_CONDITION_MSG" ] || [ -n "$FULCIO_CONDITION_REASON" ]; then
                    info "    Fulcio Status: ${FULCIO_CONDITION_REASON:-Unknown} - ${FULCIO_CONDITION_MSG:-No message}"
                fi
                # Check for Fulcio pods
                FULCIO_PODS=$(oc get pods -n $RHTAS_NAMESPACE -l app=fulcio --no-headers 2>/dev/null | wc -l || echo "0")
                if [ "$FULCIO_PODS" -gt 0 ]; then
                    FULCIO_POD_STATUS=$(oc get pods -n $RHTAS_NAMESPACE -l app=fulcio -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
                    info "    Fulcio Pods: $FULCIO_PODS pod(s), Status: ${FULCIO_POD_STATUS:-Unknown}"
                fi
            fi
        fi
        
        if [ "$REKOR_READY" = false ]; then
            if [ -n "$SECURESIGN_NAME" ]; then
                REKOR_CONDITION_MSG=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="RekorAvailable")].message}' 2>/dev/null || echo "")
                REKOR_CONDITION_REASON=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="RekorAvailable")].reason}' 2>/dev/null || echo "")
                if [ -n "$REKOR_CONDITION_MSG" ] || [ -n "$REKOR_CONDITION_REASON" ]; then
                    info "    Rekor Status: ${REKOR_CONDITION_REASON:-Unknown} - ${REKOR_CONDITION_MSG:-No message}"
                fi
            elif [ -n "$REKOR_NAME" ] && oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE >/dev/null 2>&1; then
                REKOR_CONDITION_MSG=$(oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
                REKOR_CONDITION_REASON=$(oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
                if [ -n "$REKOR_CONDITION_MSG" ] || [ -n "$REKOR_CONDITION_REASON" ]; then
                    info "    Rekor Status: ${REKOR_CONDITION_REASON:-Unknown} - ${REKOR_CONDITION_MSG:-No message}"
                fi
                # Check for Rekor pods
                REKOR_PODS=$(oc get pods -n $RHTAS_NAMESPACE -l app=rekor --no-headers 2>/dev/null | wc -l || echo "0")
                if [ "$REKOR_PODS" -gt 0 ]; then
                    REKOR_POD_STATUS=$(oc get pods -n $RHTAS_NAMESPACE -l app=rekor -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
                    info "    Rekor Pods: $REKOR_PODS pod(s), Status: ${REKOR_POD_STATUS:-Unknown}"
                fi
            fi
        fi
    fi
done

# Get final URLs if not already set
if [ "$TUF_READY" = false ]; then
    if [ -n "$SECURESIGN_NAME" ]; then
        TUF_URL=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.tuf.url}' 2>/dev/null || echo "")
    elif [ -n "$TUF_NAME" ]; then
        TUF_URL=$(oc get tufs $TUF_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    fi
fi
if [ "$FULCIO_READY" = false ]; then
    if [ -n "$SECURESIGN_NAME" ]; then
        FULCIO_URL=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.fulcio.url}' 2>/dev/null || echo "")
    elif [ -n "$FULCIO_NAME" ]; then
        FULCIO_URL=$(oc get fulcios $FULCIO_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    fi
fi
if [ "$REKOR_READY" = false ]; then
    if [ -n "$SECURESIGN_NAME" ]; then
        REKOR_URL=$(oc get securesigns $SECURESIGN_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.rekor.url}' 2>/dev/null || echo "")
    elif [ -z "$REKOR_NAME" ]; then
        REKOR_NAME=$(oc get rekors -n $RHTAS_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "rekor-server")
    fi
    if [ -n "$REKOR_NAME" ]; then
        REKOR_URL=$(oc get rekors $REKOR_NAME -n $RHTAS_NAMESPACE -o jsonpath='{.status.url}' 2>/dev/null || echo "")
    fi
fi

# Cosign / Sigstore env file (matches module-03 workstation exports)
COSIGN_ENV_FILE="${SCRIPT_DIR}/cosign-env.sh"
if [[ -n "${TUF_URL:-}" && -n "${FULCIO_URL:-}" && -n "${REKOR_URL:-}" ]]; then
    umask 022
    {
        echo '# Generated by tssc-setup/03-deploy.sh — cluster-specific; re-run deploy to refresh.'
        printf 'export TUF_URL=%q\n' "$TUF_URL"
        printf 'export OIDC_ISSUER_URL=%q\n' "$OIDC_ISSUER_URL"
        printf 'export COSIGN_FULCIO_URL=%q\n' "$FULCIO_URL"
        printf 'export COSIGN_REKOR_URL=%q\n' "$REKOR_URL"
        printf 'export COSIGN_MIRROR=%q\n' "$TUF_URL"
        printf 'export COSIGN_ROOT=%q\n' "${TUF_URL}/root.json"
        printf 'export COSIGN_OIDC_CLIENT_ID=%q\n' "$OIDC_CLIENT_ID"
        printf 'export COSIGN_OIDC_ISSUER=%q\n' "$OIDC_ISSUER_URL"
        printf 'export COSIGN_CERTIFICATE_OIDC_ISSUER=%q\n' "$OIDC_ISSUER_URL"
        printf 'export COSIGN_YES=%q\n' "true"
        printf 'export SIGSTORE_FULCIO_URL=%q\n' "$FULCIO_URL"
        printf 'export SIGSTORE_OIDC_ISSUER=%q\n' "$OIDC_ISSUER_URL"
        printf 'export SIGSTORE_REKOR_URL=%q\n' "$REKOR_URL"
        printf 'export REKOR_REKOR_SERVER=%q\n' "$REKOR_URL"
    } >"$COSIGN_ENV_FILE"
    chmod a+r "$COSIGN_ENV_FILE"
    log "Wrote cosign/sigstore environment file: ${COSIGN_ENV_FILE}"
    log "  Load in your shell: source ${COSIGN_ENV_FILE}"
else
    warning "Skipped ${COSIGN_ENV_FILE} (missing TUF, Fulcio, and/or Rekor URL). Re-run when components report URLs."
fi

# Step 5: Summary
log ""
log "========================================================="
log "RHTAS Deployment Summary"
log "========================================================="
log "Namespace: ${RHTAS_NAMESPACE}"
log ""

if [ "$TUF_READY" = true ]; then
    log "✓ TUF: Ready"
    log "  URL: ${TUF_URL}"
else
    warning "TUF: Not ready"
fi

if [ "$FULCIO_READY" = true ]; then
    log "✓ Fulcio: Ready"
    log "  URL: ${FULCIO_URL}"
    log "  OIDC Issuer: ${OIDC_ISSUER_URL}"
    log "  OIDC Client ID: ${OIDC_CLIENT_ID}"
else
    warning "Fulcio: Not ready"
fi

if [ "$REKOR_READY" = true ]; then
    log "✓ Rekor: Ready"
    log "  URL: ${REKOR_URL}"
else
    warning "Rekor: Not ready"
fi

log ""
log "To check status:"
log "  oc get tufs,fulcios,rekors -n ${RHTAS_NAMESPACE}"
log "  oc get pods -n ${RHTAS_NAMESPACE}"
log ""
log "To diagnose issues:"
log "  oc describe tufs -n ${RHTAS_NAMESPACE}"
log "  oc describe fulcios -n ${RHTAS_NAMESPACE}"
log "  oc describe rekors -n ${RHTAS_NAMESPACE}"
log "  oc get events -n ${RHTAS_NAMESPACE} --sort-by='.lastTimestamp' | tail -20"
if [ -n "$SECURESIGN_NAME" ]; then
    log "  oc describe securesigns ${SECURESIGN_NAME} -n ${RHTAS_NAMESPACE}"
fi
log ""
if [[ -n "${TUF_URL:-}" && -n "${FULCIO_URL:-}" && -n "${REKOR_URL:-}" ]]; then
    log "Cosign / sigstore: source ${COSIGN_ENV_FILE} then run cosign initialize"
else
    log "When URLs are available, re-run this script to generate ${COSIGN_ENV_FILE}"
fi
log "========================================================="
log ""
