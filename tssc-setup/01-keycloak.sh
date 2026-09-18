#!/bin/bash
# Red Hat Single Sign-On (RHSSO) / Keycloak Operator Installation Script
# Installs the RHSSO Operator using the provided subscription configuration

# Exit immediately on error, show exact error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# RH-SSO / Keycloak install targets the hub (same as lab); parallel setup may leave another context selected.
KUBE_CONTEXT="${KUBE_CONTEXT:-local-cluster}"
oc config use-context "$KUBE_CONTEXT" &>/dev/null || true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHSSO-INSTALL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHSSO-INSTALL]${NC} $1"
}

error() {
    echo -e "${RED}[RHSSO-INSTALL] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHSSO-INSTALL] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Prerequisites validation
log "========================================================="
log "Red Hat Single Sign-On (RHSSO) Operator Installation"
log "========================================================="
log ""

log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! oc auth can-i create subscriptions --all-namespaces; then
    error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"
log ""

# Live Keycloak (RHBK or RH-SSO): Running pods and/or a route. CR Ready can lag or use a different condition type.
keycloak_instance_usable() {
    local ns=$1
    [ -z "$ns" ] && return 1
    oc get namespace "$ns" >/dev/null 2>&1 || return 1
    if oc get pods -n "$ns" --no-headers 2>/dev/null | awk '$3=="Running"' | grep -qiE 'keycloak|rhbk'; then
        return 0
    fi
    if oc get route -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' | grep -qiE 'keycloak|rhbk|^sso$'; then
        return 0
    fi
    if oc get statefulset keycloak -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'; then
        return 0
    fi
    if oc get deployment -n "$ns" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'; then
        return 0
    fi
    return 1
}

rhsso_operator_pod_running() {
    local ns=$1 podc
    [ -z "$ns" ] && return 1
    oc get namespace "$ns" >/dev/null 2>&1 || return 1
    podc=$(oc get pods -n "$ns" -l name=rhsso-operator --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    if [ "${podc:-0}" -ge 1 ]; then
        return 0
    fi
    oc get pods -n "$ns" --no-headers 2>/dev/null | awk '$3=="Running"' | grep -qi rhsso-operator
}

discover_rhsso_csv_name() {
    local ns=$1 csv_name=""
    csv_name=$(oc get csv -n "$ns" -o name 2>/dev/null | grep rhsso-operator | head -1 | sed 's|.*/||' || true)
    if [ -z "$csv_name" ]; then
        csv_name=$(oc get csv -n "$ns" -l operators.coreos.com/rhsso-operator.rhsso -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi
    if [ -z "$csv_name" ]; then
        csv_name=$(oc get csv -n "$ns" --no-headers 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /rhsso/ {print $1; exit}' || true)
    fi
    printf '%s' "$csv_name"
}

rhsso_operator_ready_in_namespace() {
    rhsso_operator_pod_running "$1"
}

# Check if Keycloak / RHSSO is already available
log "Checking if Keycloak is already installed..."
NAMESPACE="rhsso"
OPERATOR_INSTALLED=false
KEYCLOAK_RHBK_RES="keycloaks.k8s.keycloak.org"
KEYCLOAK_LEGACY_RES="keycloaks.keycloak.org"

# Lab clusters already ship Keycloak (usually RHBK in namespace "keycloak").
# Never pull redhat-operator-index just to install RH-SSO — that index image dominates setup time.
for kns in keycloak rhsso; do
    oc get namespace "$kns" >/dev/null 2>&1 || continue
    kcname=""
    if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1; then
        kcname=$(oc get "$KEYCLOAK_RHBK_RES" -n "$kns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    fi
    if [ -n "$kcname" ] || keycloak_instance_usable "$kns"; then
        log "✓ Found existing Keycloak in namespace $kns${kcname:+ (CR '$kcname')}"
        log "Skipping RH-SSO operator installation; will use this instance."
        OPERATOR_INSTALLED=true
        NAMESPACE="$kns"
        break
    fi
done

if [ "$OPERATOR_INSTALLED" = false ] && oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log "Namespace $NAMESPACE already exists"
    if rhsso_operator_ready_in_namespace "$NAMESPACE"; then
        log "✓ RHSSO operator is already running in $NAMESPACE"
        OPERATOR_INSTALLED=true
        log "Skipping operator installation, but will proceed with Keycloak instance deployment..."
    else
        log "RHSSO operator not fully ready in $NAMESPACE; proceeding with installation steps..."
    fi
elif [ "$OPERATOR_INSTALLED" = false ]; then
    log "RHSSO Operator not found, proceeding with installation..."
fi

# Install Red Hat Single Sign-On Operator (if not already installed)
if [ "$OPERATOR_INSTALLED" = false ]; then
    log ""
    log "========================================================="
    log "Installing Red Hat Single Sign-On Operator"
    log "========================================================="
    log ""
    log "Following idempotent installation steps (safe to run multiple times)..."
    log ""

    # Step 1: Create the namespace (idempotent)
    log "Step 1: Creating namespace $NAMESPACE..."
    if ! oc create ns $NAMESPACE --dry-run=client -o yaml | oc apply -f -; then
        error "Failed to create $NAMESPACE namespace"
    fi
    log "✓ Namespace created successfully"

    # Step 2: Create OperatorGroup
    log ""
    log "Step 2: Creating OperatorGroup..."
    if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhsso-operator-group
  namespace: $NAMESPACE
spec:
  targetNamespaces:
    - $NAMESPACE
EOF
    then
        error "Failed to create OperatorGroup"
    fi
    log "✓ OperatorGroup created successfully (targeting namespace: $NAMESPACE)"

    # Step 3: Subscribe from the cluster marketplace only (no extra operator-index pull).
    log ""
    log "Step 3: Using cluster Operator catalog..."

    SUB_SOURCE="redhat-operators"
    SUB_SOURCE_NS="openshift-marketplace"

    if ! oc get packagemanifest rhsso-operator -n openshift-marketplace >/dev/null 2>&1; then
        error "No Keycloak instance found and rhsso-operator is not in openshift-marketplace. This lab expects Keycloak (namespace keycloak) to already be present."
    fi
    log "✓ Found rhsso-operator in openshift-marketplace"

    # Step 4: Create the Subscription (no startingCSV pin — OLM resolves the channel CSV)
    log ""
    log "Step 4: Creating Subscription..."
    log "  Channel: stable"
    log "  Source: $SUB_SOURCE"
    log "  SourceNamespace: $SUB_SOURCE_NS"

    if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhsso-operator
  namespace: $NAMESPACE
  labels:
    operators.coreos.com/rhsso-operator.rhsso: ''
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhsso-operator
  source: $SUB_SOURCE
  sourceNamespace: $SUB_SOURCE_NS
EOF
    then
        error "Failed to create Subscription"
    fi
    log "✓ Subscription created successfully"
    # A previous run may have pinned startingCSV; apply does not remove that field.
    oc patch subscription rhsso-operator -n "$NAMESPACE" --type json \
        -p '[{"op":"remove","path":"/spec/startingCSV"}]' 2>/dev/null || true

    log "Verifying operator install progress (CSV + pods)..."
    sleep 3

    # Step 5: Wait for the operator pod (CSV name/version is not assumed)
    log ""
    log "Step 5: Waiting for RHSSO operator to come up (pod Running, up to 3 minutes)..."
    log ""

    MAX_WAIT=180
    WAIT_COUNT=0
    OPERATOR_READY=false

    while [ "$WAIT_COUNT" -lt "$MAX_WAIT" ]; do
        if rhsso_operator_pod_running "$NAMESPACE"; then
            OPERATOR_READY=true
            log "✓ RHSSO operator pod is Running"
            break
        fi

        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ "$WAIT_COUNT" -gt 0 ]; then
            log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
            oc get csv,installplan.operators.coreos.com -n "$NAMESPACE" 2>/dev/null | head -8 || true
            oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | head -8 || true
            log ""
        fi

        sleep 10
        WAIT_COUNT=$((WAIT_COUNT + 10))
    done

    CSV_NAME=$(discover_rhsso_csv_name "$NAMESPACE")

    if [ "$OPERATOR_READY" = false ] && [ -n "$CSV_NAME" ]; then
        log "Waiting for CSV '$CSV_NAME' to reach Succeeded phase..."
        if oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n "$NAMESPACE" --timeout=300s 2>/dev/null; then
            log "✓ CSV is in Succeeded phase"
            OPERATOR_READY=true
        else
            warning "CSV '$CSV_NAME' did not reach Succeeded within timeout"
        fi
    elif [ -n "$CSV_NAME" ]; then
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        log "CSV '$CSV_NAME' phase: $CSV_PHASE"
    else
        warning "CSV name not listed yet (operator pod is the readiness signal)"
    fi

    # Step 6: Final check – verify CSV and pods
    log ""
    log "Step 6: Final check - verifying CSV and pods..."
    log ""
    log "CSV status:"
    oc get csv -n "$NAMESPACE" 2>/dev/null || log "  No CSV found"
    log ""
    log "Operator pod status:"
    oc get pods -n "$NAMESPACE" 2>/dev/null || log "  No pods found"
    log ""

    # Step 7: Verify final status
    log "Step 7: Final verification..."
    log ""

    if [ -n "$CSV_NAME" ]; then
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            log "✓ CSV Phase: Succeeded"
        else
            warning "CSV Phase: $CSV_PHASE (operator pod Running is sufficient to continue)"
        fi
    fi

    if rhsso_operator_pod_running "$NAMESPACE"; then
        log "✓ RHSSO operator pod is Running"
        OPERATOR_READY=true
    else
        warning "RHSSO operator pod is not Running yet"
    fi

    if [ "$OPERATOR_READY" = false ]; then
        error "RHSSO operator did not become ready. Check: oc get pods,csv,catalogsource -n $NAMESPACE"
    fi

    log ""
    log "========================================================="
    log "RHSSO Operator installation completed!"
    log "========================================================="
    log "Namespace: $NAMESPACE"
    log "Operator: rhsso-operator"
    if [ -n "$CSV_NAME" ]; then
        log "CSV: $CSV_NAME"
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        log "CSV Phase: $CSV_PHASE"
    fi
    log "========================================================="
    log ""
else
    CSV_NAME=$(discover_rhsso_csv_name "$NAMESPACE")

    log ""
    log "========================================================="
    log "Keycloak / RHSSO Status"
    log "========================================================="
    log "Namespace: $NAMESPACE"
    if [ -n "$CSV_NAME" ]; then
        log "CSV: $CSV_NAME"
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        log "CSV Phase: $CSV_PHASE"
    fi
    log "========================================================="
    log ""
fi

# Step 8: Deploy Keycloak instance
log ""
log "========================================================="
log "Step 8: Deploying Keycloak instance"
log "========================================================="
log ""

KEYCLOAK_CR_NAME="rhsso-instance"
# legacy = keycloak.org/v1alpha1 (RH-SSO operator); rhbk = k8s.keycloak.org/v2 (Red Hat build of Keycloak operator)
KEYCLOAK_API="legacy"
# Short name "keycloaks" is ambiguous when both operators' CRDs exist — always use full resource for RHBK.
KEYCLOAK_RHBK_RES="keycloaks.k8s.keycloak.org"
KEYCLOAK_LEGACY_RES="keycloaks.keycloak.org"
CR_EXISTS=false

# Red Hat build of Keycloak: Keycloak CR is k8s.keycloak.org (v2alpha1), usually namespace "keycloak".
# Legacy keycloak.org/v1alpha1 is not installed on those clusters — use existing CR only.
if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1; then
    for kns in keycloak rhsso; do
        oc get namespace "$kns" >/dev/null 2>&1 || continue
        kcname=$(oc get "$KEYCLOAK_RHBK_RES" -n "$kns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -n "$kcname" ]; then
            NAMESPACE="$kns"
            KEYCLOAK_CR_NAME="$kcname"
            KEYCLOAK_CRD="keycloaks"
            KEYCLOAK_API="rhbk"
            CR_EXISTS=true
            log "Detected Keycloak (k8s.keycloak.org) '$KEYCLOAK_CR_NAME' in namespace $NAMESPACE — skipping legacy keycloak.org/v1alpha1 CR"
            break
        fi
    done
fi

# Determine the correct resource name (try both singular and plural) — RH-SSO / legacy path only
# The error message showed "keycloaks.k8s.keycloak.org", so try plural first
if [ "$KEYCLOAK_API" = "legacy" ]; then
KEYCLOAK_CRD="keycloaks"
if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloaks.keycloak.org >/dev/null 2>&1; then
    log "Detected Keycloak CRD: keycloaks"
    KEYCLOAK_CRD="keycloaks"
elif oc get crd keycloak.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloak.keycloak.org >/dev/null 2>&1; then
    log "Detected Keycloak CRD: keycloak"
    KEYCLOAK_CRD="keycloak"
else
    # Try to determine by attempting to list resources (prefer legacy API name when both CRDs exist)
    if oc get "$KEYCLOAK_LEGACY_RES" -n $NAMESPACE >/dev/null 2>&1; then
        KEYCLOAK_CRD="keycloaks"
        log "Using resource name: keycloaks (detected via API)"
    elif oc get keycloak -n $NAMESPACE >/dev/null 2>&1; then
        KEYCLOAK_CRD="keycloak"
        log "Using resource name: keycloak (detected via API)"
    else
        # Default to keycloak (singular) as that's what the manifest uses
        KEYCLOAK_CRD="keycloak"
        warning "Could not determine Keycloak resource name, defaulting to 'keycloak'"
    fi
fi

# Check if Keycloak CR already exists
if oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE >/dev/null 2>&1; then
    CR_EXISTS=true
else
    # Try the other resource name in case detection was wrong
    if [ "$KEYCLOAK_CRD" = "keycloak" ]; then
        if oc get "$KEYCLOAK_LEGACY_RES" "$KEYCLOAK_CR_NAME" -n $NAMESPACE >/dev/null 2>&1; then
            KEYCLOAK_CRD="keycloaks"
            CR_EXISTS=true
            log "Found CR using resource name: keycloaks"
        fi
    elif [ "$KEYCLOAK_CRD" = "keycloaks" ]; then
        if oc get keycloak $KEYCLOAK_CR_NAME -n $NAMESPACE >/dev/null 2>&1; then
            KEYCLOAK_CRD="keycloak"
            CR_EXISTS=true
            log "Found CR using resource name: keycloak"
        fi
    fi
    
    # Check if there are any Keycloak CRs with different names
    if [ "$CR_EXISTS" = false ]; then
        EXISTING_CRS=$(oc get $KEYCLOAK_CRD -n $NAMESPACE -o name 2>/dev/null || echo "")
        if [ -z "$EXISTING_CRS" ] && [ "$KEYCLOAK_CRD" = "keycloak" ]; then
            EXISTING_CRS=$(oc get "$KEYCLOAK_LEGACY_RES" -n $NAMESPACE -o name 2>/dev/null || echo "")
            if [ -n "$EXISTING_CRS" ]; then
                KEYCLOAK_CRD="keycloaks"
                log "Found existing Keycloak CRs, using resource name: keycloaks"
            fi
        fi
        if [ -n "$EXISTING_CRS" ]; then
            warning "Found existing Keycloak CR(s) but not '$KEYCLOAK_CR_NAME':"
            echo "$EXISTING_CRS" | sed 's/^/  /'
            log "Will create new CR: $KEYCLOAK_CR_NAME"
        fi
    fi
fi
fi

# Cluster has only Red Hat build of Keycloak (k8s.keycloak.org): legacy keycloak.org CRD is absent.
# Re-discover with explicit API if short-name discovery missed the instance (e.g. name is not rhsso-instance).
if [ "$KEYCLOAK_API" = "legacy" ] && [ "$CR_EXISTS" = false ] && \
        oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1 && \
        ! oc get crd keycloaks.keycloak.org >/dev/null 2>&1; then
    for kns in keycloak rhsso; do
        oc get namespace "$kns" >/dev/null 2>&1 || continue
        kcname=$(oc get "$KEYCLOAK_RHBK_RES" -n "$kns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [ -n "$kcname" ]; then
            NAMESPACE="$kns"
            KEYCLOAK_CR_NAME="$kcname"
            KEYCLOAK_CRD="keycloaks"
            KEYCLOAK_API="rhbk"
            CR_EXISTS=true
            log "Using existing Red Hat build of Keycloak '$KEYCLOAK_CR_NAME' in namespace $NAMESPACE (legacy keycloak.org/v1alpha1 is not installed on this cluster)"
            break
        fi
    done
fi

# Unambiguous resource for oc get (short name "keycloaks" matches two API groups on some clusters)
KEYCLOAK_GET_RES="$KEYCLOAK_CRD"
if [ "$KEYCLOAK_API" = "rhbk" ]; then
    KEYCLOAK_GET_RES="$KEYCLOAK_RHBK_RES"
elif [ "$KEYCLOAK_CRD" = "keycloaks" ]; then
    KEYCLOAK_GET_RES="$KEYCLOAK_LEGACY_RES"
fi

if [ "$CR_EXISTS" = true ]; then
    log "Keycloak CR '$KEYCLOAK_CR_NAME' already exists"
    
    # Check if it's ready (RH-SSO uses .status.ready; RHBK k8s.keycloak.org uses status.conditions)
    if [ "$KEYCLOAK_API" = "rhbk" ]; then
        KEYCLOAK_READY=$(oc get "$KEYCLOAK_RHBK_RES" "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        KEYCLOAK_PHASE=$(oc get "$KEYCLOAK_RHBK_RES" "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")
    else
        KEYCLOAK_READY=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        KEYCLOAK_PHASE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    fi
    
    if [ "$KEYCLOAK_READY" = "true" ] || [ "$KEYCLOAK_READY" = "True" ]; then
        log "✓ Keycloak instance is already ready"
        if [ "$KEYCLOAK_API" = "rhbk" ]; then
            KEYCLOAK_EXTERNAL_URL=$(oc get "$KEYCLOAK_RHBK_RES" "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.hostname.hostname}' 2>/dev/null || echo "")
            [ -n "$KEYCLOAK_EXTERNAL_URL" ] && KEYCLOAK_EXTERNAL_URL="https://${KEYCLOAK_EXTERNAL_URL}"
        else
            KEYCLOAK_EXTERNAL_URL=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.externalURL}' 2>/dev/null || echo "")
        fi
        if [ -n "$KEYCLOAK_EXTERNAL_URL" ]; then
            log "  External URL: $KEYCLOAK_EXTERNAL_URL"
        fi
    else
        log "Keycloak instance exists but is not ready yet (phase: ${KEYCLOAK_PHASE:-unknown})"
        log "Waiting for it to become ready..."
    fi
else
    if [ "$KEYCLOAK_API" = "rhbk" ]; then
        error "k8s.keycloak.org Keycloak CR expected but none found in namespaces keycloak or rhsso. Create a Keycloak instance or install the operator."
    fi
    if ! oc get crd keycloaks.keycloak.org >/dev/null 2>&1; then
        error "Cannot create RH-SSO Keycloak (keycloak.org/v1alpha1): CRD keycloaks.keycloak.org is not installed. This cluster appears to use Red Hat build of Keycloak (k8s.keycloak.org) only. Re-run with: bash tssc-setup/setup.sh --skip-keycloak"
    fi
    log "Creating Keycloak CR '$KEYCLOAK_CR_NAME'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: Keycloak
metadata:
  name: $KEYCLOAK_CR_NAME
  namespace: $NAMESPACE
  labels:
    app: sso
spec:
  externalAccess:
    enabled: true
  instances: 1
EOF
    then
        error "Failed to create Keycloak CR"
    fi
    log "✓ Keycloak CR created successfully"
    
    # Give the operator a moment to start processing the CR
    log "Waiting a few seconds for operator to start processing..."
    sleep 5
fi

# Wait for Keycloak instance to be ready
log ""
log "Waiting for Keycloak instance to be ready..."

if keycloak_instance_usable "$NAMESPACE"; then
    log "✓ Keycloak is already serving (Running pods and/or route)"
    KEYCLOAK_READY=true
else
log "Note: Transient reconciliation conflicts are normal during startup and will be retried automatically."
MAX_WAIT=180
WAIT_COUNT=0
KEYCLOAK_READY=false
LAST_PHASE=""
LAST_MESSAGE=""

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if keycloak_instance_usable "$NAMESPACE"; then
        KEYCLOAK_READY=true
        log "✓ Keycloak instance is ready (workload)"
        break
    fi

    # Check if CR exists first
    if ! oc get "$KEYCLOAK_GET_RES" "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            warning "Keycloak CR '$KEYCLOAK_CR_NAME' not found. It may have been deleted or not created properly."
            if [ "$KEYCLOAK_API" = "legacy" ]; then
            log "Attempting to recreate..."
            # Try to recreate the CR (RH-SSO / keycloak.org only)
            if ! cat <<EOF | oc apply -f - 2>&1
apiVersion: keycloak.org/v1alpha1
kind: Keycloak
metadata:
  name: $KEYCLOAK_CR_NAME
  namespace: $NAMESPACE
  labels:
    app: sso
spec:
  externalAccess:
    enabled: true
  instances: 1
EOF
            then
                warning "Failed to recreate CR. Will continue checking..."
            else
                log "CR recreated, waiting for operator to process..."
                sleep 5
            fi
            fi
        fi
        KEYCLOAK_READY_STATUS="false"
        KEYCLOAK_PHASE=""
        KEYCLOAK_MESSAGE="CR not found"
    else
        if [ "$KEYCLOAK_API" = "rhbk" ]; then
            KEYCLOAK_READY_STATUS=$(oc get "$KEYCLOAK_RHBK_RES" "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
            KEYCLOAK_PHASE=$(oc get "$KEYCLOAK_RHBK_RES" "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "")
            KEYCLOAK_MESSAGE=$(oc get "$KEYCLOAK_RHBK_RES" "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="HasErrors")].message}' 2>/dev/null || echo "")
        else
            KEYCLOAK_READY_STATUS=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
            KEYCLOAK_PHASE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            KEYCLOAK_MESSAGE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.message}' 2>/dev/null || echo "")
        fi
    fi
    
    if [ "$KEYCLOAK_READY_STATUS" = "true" ] || [ "$KEYCLOAK_READY_STATUS" = "True" ]; then
        KEYCLOAK_READY=true
        log "✓ Keycloak instance is ready"
        break
    fi
    
    # If CR doesn't exist, check if resources are running anyway (CR may have been deleted but resources remain)
    if [ "$KEYCLOAK_MESSAGE" = "CR not found" ]; then
        KEYCLOAK_STS_READY=$(oc get statefulset keycloak -n $NAMESPACE -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
        KEYCLOAK_POD_RUNNING=$(oc get pod -n $NAMESPACE -l app=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        
        if [ "$KEYCLOAK_STS_READY" = "1/1" ] && [ "$KEYCLOAK_POD_RUNNING" = "Running" ]; then
            log "✓ Keycloak resources are running (StatefulSet: $KEYCLOAK_STS_READY, Pod: $KEYCLOAK_POD_RUNNING)"
            log "  Note: Keycloak CR not found, but resources are healthy. Installation appears successful."
            KEYCLOAK_READY=true
            break
        fi
    fi
    
    # Show progress every 30 seconds or if phase/message changed
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
        log "  Phase: ${KEYCLOAK_PHASE:-unknown}"
        log "  Ready: ${KEYCLOAK_READY_STATUS:-false}"
        
        # Show status message if present
        if [ -n "$KEYCLOAK_MESSAGE" ] && [ "$KEYCLOAK_MESSAGE" != "$LAST_MESSAGE" ]; then
            if echo "$KEYCLOAK_MESSAGE" | grep -qi "cannot be fulfilled\|modified\|conflict"; then
                warning "  Status message: $KEYCLOAK_MESSAGE"
                log "  (This is a transient reconciliation conflict - the operator will retry automatically)"
            else
                log "  Status message: $KEYCLOAK_MESSAGE"
            fi
            LAST_MESSAGE="$KEYCLOAK_MESSAGE"
        fi
        
        # Show pod status
        KEYCLOAK_PODS=$(oc get pods -n $NAMESPACE -l app=keycloak -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
        if [ -n "$KEYCLOAK_PODS" ]; then
            log "  Keycloak pods: $KEYCLOAK_PODS"
        fi
        
        # Show StatefulSet status
        KEYCLOAK_STS=$(oc get statefulset keycloak -n $NAMESPACE -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
        if [ -n "$KEYCLOAK_STS" ] && [ "$KEYCLOAK_STS" != "/" ]; then
            log "  StatefulSet ready: $KEYCLOAK_STS"
        fi
        
        # Show phase change
        if [ "$KEYCLOAK_PHASE" != "$LAST_PHASE" ] && [ -n "$LAST_PHASE" ]; then
            log "  Phase changed: $LAST_PHASE -> $KEYCLOAK_PHASE"
        fi
        LAST_PHASE="$KEYCLOAK_PHASE"
        
        log ""
    fi
    
    # Check for persistent errors (not transient conflicts)
    if [ -n "$KEYCLOAK_MESSAGE" ] && ! echo "$KEYCLOAK_MESSAGE" | grep -qi "cannot be fulfilled\|modified\|conflict\|reconciling"; then
        if echo "$KEYCLOAK_MESSAGE" | grep -qi "error\|failed\|denied"; then
            if [ $((WAIT_COUNT % 60)) -eq 0 ] && [ $WAIT_COUNT -gt 60 ]; then
                warning "Persistent error detected: $KEYCLOAK_MESSAGE"
                warning "Check operator logs: oc logs -n $NAMESPACE -l name=rhsso-operator --tail=50"
            fi
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
done

if [ "$KEYCLOAK_READY" = false ]; then
    # Final check: even if CR doesn't exist, check if resources are running
    KEYCLOAK_STS_READY=$(oc get statefulset keycloak -n $NAMESPACE -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
    KEYCLOAK_POD_RUNNING=$(oc get pod -n $NAMESPACE -l app=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    
    if [ "$KEYCLOAK_STS_READY" = "1/1" ] && [ "$KEYCLOAK_POD_RUNNING" = "Running" ]; then
        log "✓ Keycloak resources are running despite CR check timeout"
        log "  StatefulSet: $KEYCLOAK_STS_READY"
        log "  Pod status: $KEYCLOAK_POD_RUNNING"
        log "  Installation appears successful even though CR was not found."
        KEYCLOAK_READY=true
    else
        warning "Keycloak instance did not become ready within ${MAX_WAIT} seconds"
        log ""
        
        # Check if CR exists before trying to get status
        if oc get "$KEYCLOAK_GET_RES" "$KEYCLOAK_CR_NAME" -n $NAMESPACE >/dev/null 2>&1; then
            log "Current Keycloak CR status:"
            oc get "$KEYCLOAK_GET_RES" "$KEYCLOAK_CR_NAME" -n $NAMESPACE -o yaml | grep -A 10 "status:" || oc get "$KEYCLOAK_GET_RES" "$KEYCLOAK_CR_NAME" -n $NAMESPACE
            log ""
            
            # Check for reconciliation conflicts
            KEYCLOAK_MESSAGE=$(oc get "$KEYCLOAK_GET_RES" "$KEYCLOAK_CR_NAME" -n $NAMESPACE -o jsonpath='{.status.message}' 2>/dev/null || echo "")
        else
        warning "Keycloak CR '$KEYCLOAK_CR_NAME' does not exist!"
        log ""
        log "Checking for available Keycloak CRs:"
        oc get "$KEYCLOAK_GET_RES" -n $NAMESPACE 2>&1 || log "  No Keycloak CRs found"
        log ""
            log "Checking CRD availability:"
            oc get crd | grep -i keycloak || log "  No Keycloak CRD found"
            log ""
            KEYCLOAK_MESSAGE="CR not found"
        fi
        
        if echo "$KEYCLOAK_MESSAGE" | grep -qi "cannot be fulfilled\|modified\|conflict"; then
            log "Detected reconciliation conflicts. This is usually transient."
            log "The operator will continue retrying. You can check progress with:"
            log "  oc get $KEYCLOAK_GET_RES $KEYCLOAK_CR_NAME -n $NAMESPACE -o yaml | grep -A 5 status"
            log "  oc logs -n $NAMESPACE -l name=rhsso-operator --tail=50"
        else
            if [ "$KEYCLOAK_MESSAGE" = "CR not found" ]; then
                warning "Keycloak CR was not found. The CR may need to be created manually."
                log "To create the CR, run:"
                log "  cat <<EOF | oc apply -f -"
                log "apiVersion: keycloak.org/v1alpha1"
                log "kind: Keycloak"
                log "metadata:"
                log "  name: $KEYCLOAK_CR_NAME"
                log "  namespace: $NAMESPACE"
                log "  labels:"
                log "    app: sso"
                log "spec:"
                log "  externalAccess:"
                log "    enabled: true"
                log "  instances: 1"
                log "EOF"
            else
                warning "Keycloak may still be installing or there may be an issue."
                log "Check operator logs: oc logs -n $NAMESPACE -l name=rhsso-operator --tail=100"
            fi
        fi
        log ""
        log "To check status: oc get $KEYCLOAK_GET_RES $KEYCLOAK_CR_NAME -n $NAMESPACE"
        log "To check pods: oc get pods -n $NAMESPACE"
    fi
else
    log "✓ Keycloak instance is ready"
fi
fi

# Get Keycloak URLs and credentials
log ""
log "Retrieving Keycloak access information..."

# Try to get URLs from CR first
if [ "$KEYCLOAK_API" = "rhbk" ]; then
    KEYCLOAK_EXTERNAL_URL=$(oc get "$KEYCLOAK_RHBK_RES" "$KEYCLOAK_CR_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.hostname.hostname}' 2>/dev/null || echo "")
    [ -n "$KEYCLOAK_EXTERNAL_URL" ] && KEYCLOAK_EXTERNAL_URL="https://${KEYCLOAK_EXTERNAL_URL}"
    KEYCLOAK_INTERNAL_URL=""
    KEYCLOAK_CREDENTIAL_SECRET=""
else
    KEYCLOAK_EXTERNAL_URL=$(oc get "$KEYCLOAK_GET_RES" "$KEYCLOAK_CR_NAME" -n $NAMESPACE -o jsonpath='{.status.externalURL}' 2>/dev/null || echo "")
    KEYCLOAK_INTERNAL_URL=$(oc get "$KEYCLOAK_GET_RES" "$KEYCLOAK_CR_NAME" -n $NAMESPACE -o jsonpath='{.status.internalURL}' 2>/dev/null || echo "")
    KEYCLOAK_CREDENTIAL_SECRET=$(oc get "$KEYCLOAK_GET_RES" "$KEYCLOAK_CR_NAME" -n $NAMESPACE -o jsonpath='{.status.credentialSecret}' 2>/dev/null || echo "")
fi

# If CR doesn't exist, try to get URL from route
if [ -z "$KEYCLOAK_EXTERNAL_URL" ]; then
    KEYCLOAK_EXTERNAL_URL=$(oc get route keycloak -n $NAMESPACE -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
fi

# If still no URL, try to get from service
if [ -z "$KEYCLOAK_INTERNAL_URL" ]; then
    KEYCLOAK_SVC=$(oc get svc keycloak -n $NAMESPACE -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
    if [ -n "$KEYCLOAK_SVC" ]; then
        KEYCLOAK_INTERNAL_URL="https://${KEYCLOAK_SVC}.${NAMESPACE}.svc.cluster.local:8443"
    fi
fi

# Try to find credential secret if not from CR
if [ -z "$KEYCLOAK_CREDENTIAL_SECRET" ]; then
    # Look for credential secrets
    KEYCLOAK_CREDENTIAL_SECRET=$(oc get secret -n $NAMESPACE -l app=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$KEYCLOAK_CREDENTIAL_SECRET" ]; then
        # Try common secret names
        for secret_name in "credential-rhsso-instance" "keycloak-credential" "rhsso-instance-credential"; do
            if oc get secret $secret_name -n $NAMESPACE >/dev/null 2>&1; then
                KEYCLOAK_CREDENTIAL_SECRET=$secret_name
                break
            fi
        done
    fi
fi

KEYCLOAK_USERNAME=""
KEYCLOAK_PASSWORD=""

if [ -n "$KEYCLOAK_CREDENTIAL_SECRET" ]; then
    KEYCLOAK_USERNAME=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $NAMESPACE -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    KEYCLOAK_PASSWORD=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $NAMESPACE -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi

log ""
log "========================================================="
log "Keycloak Installation Summary"
log "========================================================="
log "Namespace: $NAMESPACE"
if oc get "$KEYCLOAK_GET_RES" "$KEYCLOAK_CR_NAME" -n $NAMESPACE >/dev/null 2>&1; then
    log "Keycloak CR: $KEYCLOAK_CR_NAME"
    log "Status: Ready"
else
    log "Keycloak CR: $KEYCLOAK_CR_NAME (not found, but resources are running)"
    log "Status: Ready (resources verified)"
fi
log ""
if [ -n "$KEYCLOAK_EXTERNAL_URL" ]; then
    log "External URL: $KEYCLOAK_EXTERNAL_URL"
fi
if [ -n "$KEYCLOAK_INTERNAL_URL" ]; then
    log "Internal URL: $KEYCLOAK_INTERNAL_URL"
fi
if [ -n "$KEYCLOAK_USERNAME" ] && [ -n "$KEYCLOAK_PASSWORD" ]; then
    log "Username: $KEYCLOAK_USERNAME"
    log "Password: $KEYCLOAK_PASSWORD"
elif [ -n "$KEYCLOAK_CREDENTIAL_SECRET" ]; then
    log "Credentials: Stored in secret '$KEYCLOAK_CREDENTIAL_SECRET'"
    log "  To retrieve: oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $NAMESPACE -o jsonpath='{.data.username}' | base64 -d"
    log "  To retrieve: oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d"
fi
log "========================================================="
log ""
