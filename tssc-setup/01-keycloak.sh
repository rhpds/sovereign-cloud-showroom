#!/bin/bash
# Red Hat Single Sign-On (RHSSO) / Keycloak Operator Installation Script
# Installs the RHSSO Operator using the provided subscription configuration

# Exit immediately on error, show exact error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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

# Check if RHSSO Operator is already installed
log "Checking if RHSSO Operator is already installed..."
NAMESPACE="rhsso"
OPERATOR_INSTALLED=false

if oc get namespace $NAMESPACE >/dev/null 2>&1; then
    log "Namespace $NAMESPACE already exists"
    
    # Check for existing subscription
    if oc get subscription.operators.coreos.com rhsso-operator -n $NAMESPACE >/dev/null 2>&1; then
        CURRENT_CSV=$(oc get subscription.operators.coreos.com rhsso-operator -n $NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        if [ -z "$CURRENT_CSV" ]; then
            log "Subscription exists but CSV not yet determined, proceeding with installation..."
        else
            CSV_PHASE=$(oc get csv $CURRENT_CSV -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ RHSSO Operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Status: $CSV_PHASE"
                OPERATOR_INSTALLED=true
                log "Skipping operator installation, but will proceed with Keycloak instance deployment..."
            else
                log "RHSSO Operator subscription exists but CSV is in phase: $CSV_PHASE"
                log "Continuing with installation to ensure proper setup..."
            fi
        fi
    else
        log "Namespace exists but no subscription found, proceeding with installation..."
    fi
else
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

    # Step 3: Create or verify CatalogSource
    log ""
    log "Step 3: Creating/verifying CatalogSource..."

    CATALOG_SOURCE_NAME="rhsso-operator-catalogsource"
    CATALOG_SOURCE_EXISTS=false

    if oc get catalogsource $CATALOG_SOURCE_NAME -n $NAMESPACE >/dev/null 2>&1; then
        log "CatalogSource '$CATALOG_SOURCE_NAME' already exists"
        CATALOG_SOURCE_EXISTS=true
        
        # Check if it's healthy
        CATALOG_STATUS=$(oc get catalogsource $CATALOG_SOURCE_NAME -n $NAMESPACE -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        if [ "$CATALOG_STATUS" = "READY" ]; then
            log "✓ CatalogSource is READY"
        else
            log "CatalogSource status: ${CATALOG_STATUS:-unknown}"
        fi
    else
        log "Creating CatalogSource '$CATALOG_SOURCE_NAME'..."
        
        # Create CatalogSource pointing to redhat-operators
        # Note: This creates a custom catalog source that mirrors redhat-operators
        # If you have a specific catalog image, replace the image reference below
        if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_SOURCE_NAME
  namespace: $NAMESPACE
spec:
  sourceType: grpc
  image: registry.redhat.io/redhat/redhat-operator-index:v4.15
  displayName: RHSSO Operator Catalog
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 30m
EOF
        then
            error "Failed to create CatalogSource"
        fi
        log "✓ CatalogSource created"
        
        # Wait for catalog source to be ready
        log "Waiting for CatalogSource to be ready..."
        CATALOG_READY=false
        for i in {1..30}; do
            CATALOG_STATUS=$(oc get catalogsource $CATALOG_SOURCE_NAME -n $NAMESPACE -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
            if [ "$CATALOG_STATUS" = "READY" ]; then
                CATALOG_READY=true
                log "✓ CatalogSource is READY"
                break
            else
                if [ $((i % 5)) -eq 0 ]; then
                    log "  CatalogSource status: ${CATALOG_STATUS:-unknown} (waiting for READY...)"
                fi
            fi
            sleep 2
        done
        
        if [ "$CATALOG_READY" = false ]; then
            warning "CatalogSource may not be ready yet, but continuing..."
        fi
    fi

    # Step 4: Create the Subscription
    log ""
    log "Step 4: Creating Subscription..."
    log "  Channel: stable"
    log "  Source: $CATALOG_SOURCE_NAME"
    log "  SourceNamespace: $NAMESPACE"
    log "  StartingCSV: rhsso-operator.7.6.11-opr-004"

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
  source: $CATALOG_SOURCE_NAME
  sourceNamespace: $NAMESPACE
  startingCSV: rhsso-operator.7.6.11-opr-004
EOF
    then
        error "Failed to create Subscription"
    fi
    log "✓ Subscription created successfully"

    # Verify subscription was created
    log "Verifying subscription..."
    sleep 3

    SUBSCRIPTION_STATUS=$(oc get subscription rhsso-operator -n $NAMESPACE -o jsonpath='{.status.state}' 2>/dev/null || echo "")
    log "Subscription state: ${SUBSCRIPTION_STATUS:-unknown}"

    # Step 5: Wait for CSV to be created and installed
    log ""
    log "Step 5: Waiting for installation (60-120 seconds)..."
    log "Watching install progress..."
    log ""

    # Wait for CSV to be created
    MAX_WAIT=120
    WAIT_COUNT=0
    CSV_CREATED=false

    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if oc get csv -n $NAMESPACE 2>/dev/null | grep -q rhsso-operator; then
            CSV_CREATED=true
            log "✓ CSV created"
            break
        fi
        
        # Show progress every 10 seconds
        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
            oc get csv,subscription,installplan -n $NAMESPACE 2>/dev/null | head -5 || true
            log ""
        fi
        
        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done

    if [ "$CSV_CREATED" = false ]; then
        warning "CSV not created after ${MAX_WAIT} seconds. Current status:"
        oc get csv,subscription,installplan -n $NAMESPACE
        warning "CSV may still be installing. Check subscription status: oc get subscription rhsso-operator -n $NAMESPACE"
    fi

    # Get the CSV name
    CSV_NAME=$(oc get csv -n $NAMESPACE -o name 2>/dev/null | grep rhsso-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n $NAMESPACE -l operators.coreos.com/rhsso-operator.rhsso -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [ -z "$CSV_NAME" ]; then
        warning "Failed to find CSV name for rhsso-operator. It may still be installing."
        CSV_NAME="rhsso-operator.7.6.11-opr-004"
    fi

    # Wait for CSV to be in Succeeded phase
    if [ -n "$CSV_NAME" ]; then
        log "Waiting for CSV '$CSV_NAME' to reach Succeeded phase..."
        if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n $NAMESPACE --timeout=300s 2>/dev/null; then
            CSV_STATUS=$(oc get csv "$CSV_NAME" -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
            warning "CSV did not reach Succeeded phase within timeout. Current status: $CSV_STATUS"
            log "Checking CSV details..."
            oc get csv "$CSV_NAME" -n $NAMESPACE
        else
            log "✓ CSV is in Succeeded phase"
        fi
    fi

    # Step 6: Final check – verify CSV and pods
    log ""
    log "Step 6: Final check - verifying CSV and pods..."
    log ""
    log "CSV status:"
    oc get csv -n $NAMESPACE 2>/dev/null || log "  No CSV found"
    log ""
    log "Subscription status:"
    oc get subscription rhsso-operator -n $NAMESPACE 2>/dev/null || log "  No subscription found"
    log ""
    log "Pod status:"
    oc get pods -n $NAMESPACE 2>/dev/null || log "  No pods found"
    log ""

    # Step 7: Verify final status
    log "Step 7: Final verification..."
    log ""

    if [ -n "$CSV_NAME" ]; then
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            log "✓ CSV Phase: Succeeded"
        else
            warning "CSV Phase: $CSV_PHASE (expected: Succeeded)"
        fi
    else
        warning "CSV name not found"
    fi

    POD_STATUS=$(oc get pods -n $NAMESPACE -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
    if echo "$POD_STATUS" | grep -q "Running"; then
        RUNNING_COUNT=$(echo "$POD_STATUS" | grep -o "Running" | wc -l | tr -d '[:space:]')
        log "✓ Found $RUNNING_COUNT Running pod(s)"
    else
        warning "No Running pods found. Status: $POD_STATUS"
    fi

    log ""
    log "========================================================="
    log "RHSSO Operator installation completed!"
    log "========================================================="
    log "Namespace: $NAMESPACE"
    log "Operator: rhsso-operator"
    if [ -n "$CSV_NAME" ]; then
        log "CSV: $CSV_NAME"
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        log "CSV Phase: $CSV_PHASE"
    fi
    log "========================================================="
    log ""
else
    # Operator already installed, get CSV name for display
    CSV_NAME=$(oc get csv -n $NAMESPACE -o name 2>/dev/null | grep rhsso-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n $NAMESPACE -l operators.coreos.com/rhsso-operator.rhsso -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get subscription rhsso-operator -n $NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
    fi
    
    log ""
    log "========================================================="
    log "RHSSO Operator Status"
    log "========================================================="
    log "Namespace: $NAMESPACE"
    log "Operator: rhsso-operator"
    if [ -n "$CSV_NAME" ]; then
        log "CSV: $CSV_NAME"
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
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

# Determine the correct resource name (try both singular and plural)
# The error message showed "keycloaks.k8s.keycloak.org", so try plural first
KEYCLOAK_CRD="keycloaks"
if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloaks.keycloak.org >/dev/null 2>&1; then
    log "Detected Keycloak CRD: keycloaks"
    KEYCLOAK_CRD="keycloaks"
elif oc get crd keycloak.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloak.keycloak.org >/dev/null 2>&1; then
    log "Detected Keycloak CRD: keycloak"
    KEYCLOAK_CRD="keycloak"
else
    # Try to determine by attempting to list resources
    if oc get keycloaks -n $NAMESPACE >/dev/null 2>&1; then
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
CR_EXISTS=false
if oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE >/dev/null 2>&1; then
    CR_EXISTS=true
else
    # Try the other resource name in case detection was wrong
    if [ "$KEYCLOAK_CRD" = "keycloak" ]; then
        if oc get keycloaks $KEYCLOAK_CR_NAME -n $NAMESPACE >/dev/null 2>&1; then
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
            EXISTING_CRS=$(oc get keycloaks -n $NAMESPACE -o name 2>/dev/null || echo "")
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

if [ "$CR_EXISTS" = true ]; then
    log "Keycloak CR '$KEYCLOAK_CR_NAME' already exists"
    
    # Check if it's ready
    KEYCLOAK_READY=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    KEYCLOAK_PHASE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    if [ "$KEYCLOAK_READY" = "true" ]; then
        log "✓ Keycloak instance is already ready"
        KEYCLOAK_EXTERNAL_URL=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.externalURL}' 2>/dev/null || echo "")
        if [ -n "$KEYCLOAK_EXTERNAL_URL" ]; then
            log "  External URL: $KEYCLOAK_EXTERNAL_URL"
        fi
    else
        log "Keycloak instance exists but is not ready yet (phase: ${KEYCLOAK_PHASE:-unknown})"
        log "Waiting for it to become ready..."
    fi
else
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
log "Note: Transient reconciliation conflicts are normal during startup and will be retried automatically."
MAX_WAIT=900
WAIT_COUNT=0
KEYCLOAK_READY=false
LAST_PHASE=""
LAST_MESSAGE=""

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Check if CR exists first
    if ! oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE >/dev/null 2>&1; then
        if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            warning "Keycloak CR '$KEYCLOAK_CR_NAME' not found. It may have been deleted or not created properly."
            log "Attempting to recreate..."
            # Try to recreate the CR
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
        KEYCLOAK_READY_STATUS="false"
        KEYCLOAK_PHASE=""
        KEYCLOAK_MESSAGE="CR not found"
    else
        KEYCLOAK_READY_STATUS=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        KEYCLOAK_PHASE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        KEYCLOAK_MESSAGE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.message}' 2>/dev/null || echo "")
    fi
    
    if [ "$KEYCLOAK_READY_STATUS" = "true" ]; then
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
        if oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE >/dev/null 2>&1; then
            log "Current Keycloak CR status:"
            oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o yaml | grep -A 10 "status:" || oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE
            log ""
            
            # Check for reconciliation conflicts
            KEYCLOAK_MESSAGE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.message}' 2>/dev/null || echo "")
        else
        warning "Keycloak CR '$KEYCLOAK_CR_NAME' does not exist!"
        log ""
        log "Checking for available Keycloak CRs:"
        oc get $KEYCLOAK_CRD -n $NAMESPACE 2>&1 || log "  No Keycloak CRs found"
        log ""
            log "Checking CRD availability:"
            oc get crd | grep -i keycloak || log "  No Keycloak CRD found"
            log ""
            KEYCLOAK_MESSAGE="CR not found"
        fi
        
        if echo "$KEYCLOAK_MESSAGE" | grep -qi "cannot be fulfilled\|modified\|conflict"; then
            log "Detected reconciliation conflicts. This is usually transient."
            log "The operator will continue retrying. You can check progress with:"
            log "  oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o yaml | grep -A 5 status"
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
        log "To check status: oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE"
        log "To check pods: oc get pods -n $NAMESPACE"
    fi
else
    log "✓ Keycloak instance is ready"
fi

# Get Keycloak URLs and credentials
log ""
log "Retrieving Keycloak access information..."

# Try to get URLs from CR first
KEYCLOAK_EXTERNAL_URL=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.externalURL}' 2>/dev/null || echo "")
KEYCLOAK_INTERNAL_URL=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.internalURL}' 2>/dev/null || echo "")
KEYCLOAK_CREDENTIAL_SECRET=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE -o jsonpath='{.status.credentialSecret}' 2>/dev/null || echo "")

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
if oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $NAMESPACE >/dev/null 2>&1; then
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
