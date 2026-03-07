#!/bin/bash
# Compliance Operator Installation Script for Second Cluster (aws-us)
# Installs the Red Hat Compliance Operator in the aws-us cluster
#
# Usage:
#   ./14-compliance-operator-second-cluster.sh

# Exit immediately on error, show error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[COMPLIANCE-OP-2ND]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[COMPLIANCE-OP-2ND]${NC} $1"
}

error() {
    echo -e "${RED}[COMPLIANCE-OP-2ND] ERROR:${NC} $1" >&2
    echo -e "${RED}[COMPLIANCE-OP-2ND] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")")' ERR

# Prerequisites validation
log "========================================================="
log "Compliance Operator Installation for aws-us Cluster"
log "========================================================="
log ""

log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Use oc if available, otherwise kubectl
KUBECTL_CMD="oc"
if ! command -v oc >/dev/null 2>&1; then
    KUBECTL_CMD="kubectl"
fi

# Switch to aws-us cluster context
log "Switching to aws-us context..."
if ! $KUBECTL_CMD config use-context aws-us >/dev/null 2>&1; then
    error "Failed to switch to aws-us context. Please ensure the context exists."
fi
log "✓ Switched to aws-us context"

# Verify we're on the correct cluster
CURRENT_CONTEXT=$($KUBECTL_CMD config current-context)
log "Current context: $CURRENT_CONTEXT"

# Check if we have cluster admin privileges
log "Checking cluster admin privileges..."
if ! $KUBECTL_CMD auth can-i create subscriptions --all-namespaces; then
    error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
fi
log "✓ Cluster admin privileges confirmed"

log "Prerequisites validated successfully"
log ""

# Check if Compliance Operator is already installed
log "Checking if Compliance Operator is already installed..."
NAMESPACE="openshift-compliance"

if $KUBECTL_CMD get namespace $NAMESPACE >/dev/null 2>&1; then
    log "Namespace $NAMESPACE already exists"
    
    # Check for existing subscription
    if $KUBECTL_CMD get subscription.operators.coreos.com compliance-operator -n $NAMESPACE >/dev/null 2>&1; then
        CURRENT_CSV=$($KUBECTL_CMD get subscription.operators.coreos.com compliance-operator -n $NAMESPACE -o jsonpath='{.status.currentCSV}')
        if [ -z "$CURRENT_CSV" ]; then
            log "Subscription exists but CSV not yet determined, proceeding with installation..."
        else
            CSV_PHASE=$($KUBECTL_CMD get csv $CURRENT_CSV -n $NAMESPACE -o jsonpath='{.status.phase}')
        
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "✓ Compliance Operator is already installed and running"
                log "  Installed CSV: $CURRENT_CSV"
                log "  Status: $CSV_PHASE"
                log "Skipping installation..."
                exit 0
            else
                log "Compliance Operator subscription exists but CSV is in phase: $CSV_PHASE"
                log "Continuing with installation to ensure proper setup..."
            fi
        fi
    else
        log "Namespace exists but no subscription found, proceeding with installation..."
    fi
else
    log "Compliance Operator not found, proceeding with installation..."
fi

# Install Red Hat Compliance Operator
log ""
log "========================================================="
log "Installing Red Hat Compliance Operator"
log "========================================================="
log ""
log "Following idempotent installation steps (safe to run multiple times)..."
log ""

# Step 1: Create the namespace (idempotent)
log "Step 1: Creating namespace openshift-compliance..."
if ! $KUBECTL_CMD create ns openshift-compliance --dry-run=client -o yaml | $KUBECTL_CMD apply -f -; then
    error "Failed to create openshift-compliance namespace"
fi
log "✓ Namespace created successfully"

# Step 2: Create the correct OperatorGroup that supports global/all-namespaces mode
log ""
log "Step 2: Creating OperatorGroup with AllNamespaces mode..."
if ! cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-compliance
  namespace: openshift-compliance
spec:
  targetNamespaces: []
EOF
then
    error "Failed to create OperatorGroup"
fi
log "✓ OperatorGroup created successfully (AllNamespaces mode)"

# Step 3: Determine the correct channel
log ""
log "Step 3: Determining available channel for compliance-operator..."

# Wait for catalog to be ready
log "Waiting for catalog source to be ready..."
CATALOG_READY=false
for i in {1..12}; do
    if $KUBECTL_CMD get catalogsource redhat-operators -n openshift-marketplace >/dev/null 2>&1; then
        CATALOG_STATUS=$($KUBECTL_CMD get catalogsource redhat-operators -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        if [ "$CATALOG_STATUS" = "READY" ]; then
            CATALOG_READY=true
            log "✓ Catalog source 'redhat-operators' is READY"
            break
        else
            log "  Catalog source status: ${CATALOG_STATUS:-unknown} (waiting for READY...)"
        fi
    fi
    if [ $i -lt 12 ]; then
        sleep 5
    fi
done

if [ "$CATALOG_READY" = false ]; then
    warning "Catalog source may not be ready, but continuing..."
fi

# Check if packagemanifest exists and get available channels
log "Checking available channels for compliance-operator..."
CHANNEL=""
if $KUBECTL_CMD get packagemanifest compliance-operator -n openshift-marketplace >/dev/null 2>&1; then
    # Get available channels from packagemanifest
    AVAILABLE_CHANNELS=$($KUBECTL_CMD get packagemanifest compliance-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
    
    if [ -n "$AVAILABLE_CHANNELS" ]; then
        log "Available channels: $AVAILABLE_CHANNELS"
        
        # Try to find preferred channels in order of preference
        # Note: "stable" channel contains v1.8.0 and is the recommended channel
        PREFERRED_CHANNELS=("stable" "release-1.8" "release-1.7" "release-1.6" "release-1.5")
        
        for pref_channel in "${PREFERRED_CHANNELS[@]}"; do
            if echo "$AVAILABLE_CHANNELS" | grep -q "\b$pref_channel\b"; then
                CHANNEL="$pref_channel"
                log "✓ Selected channel: $CHANNEL"
                break
            fi
        done
        
        # If no preferred channel found, use the first available channel
        if [ -z "$CHANNEL" ]; then
            CHANNEL=$(echo "$AVAILABLE_CHANNELS" | awk '{print $1}')
            log "✓ Using first available channel: $CHANNEL"
        fi
    else
        warning "Could not determine available channels from packagemanifest"
    fi
else
    warning "Package manifest not found in catalog (may still be syncing)"
fi

# Fallback to default channel if we couldn't determine it
if [ -z "$CHANNEL" ]; then
    CHANNEL="stable"
    log "Using default channel: $CHANNEL (contains v1.8.0, will verify after subscription creation)"
fi

# Step 4: Create the OperatorHub subscription
log ""
log "Step 4: Creating Subscription..."
log "  Channel: $CHANNEL"
log "  Source: redhat-operators"
log "  SourceNamespace: openshift-marketplace"

SUBSCRIPTION_CREATED=false
if cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: compliance-operator
  namespace: openshift-compliance
spec:
  channel: $CHANNEL
  installPlanApproval: Automatic
  name: compliance-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
then
    SUBSCRIPTION_CREATED=true
    log "✓ Subscription created successfully"
else
    error "Failed to create Subscription"
fi

# Verify subscription was created and check for channel errors
log "Verifying subscription..."
sleep 3

SUBSCRIPTION_STATUS=$($KUBECTL_CMD get subscription compliance-operator -n openshift-compliance -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
SUBSCRIPTION_MESSAGE=$($KUBECTL_CMD get subscription compliance-operator -n openshift-compliance -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || echo "")

if echo "$SUBSCRIPTION_MESSAGE" | grep -qi "constraints not satisfiable\|no operators found in channel"; then
    warning "Channel '$CHANNEL' may not be available. Checking for alternative channels..."
    
    # Try to get available channels again
    if $KUBECTL_CMD get packagemanifest compliance-operator -n openshift-marketplace >/dev/null 2>&1; then
        AVAILABLE_CHANNELS=$($KUBECTL_CMD get packagemanifest compliance-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
        if [ -n "$AVAILABLE_CHANNELS" ]; then
            # Try stable channel first, then any other channel
            ALTERNATIVE_CHANNEL=""
            if echo "$AVAILABLE_CHANNELS" | grep -q "\bstable\b"; then
                ALTERNATIVE_CHANNEL="stable"
            else
                ALTERNATIVE_CHANNEL=$(echo "$AVAILABLE_CHANNELS" | awk '{print $1}')
            fi
            
            if [ -n "$ALTERNATIVE_CHANNEL" ] && [ "$ALTERNATIVE_CHANNEL" != "$CHANNEL" ]; then
                log "Updating subscription to use channel: $ALTERNATIVE_CHANNEL"
                $KUBECTL_CMD patch subscription compliance-operator -n openshift-compliance --type merge -p "{\"spec\":{\"channel\":\"$ALTERNATIVE_CHANNEL\"}}" || warning "Failed to update channel"
                CHANNEL="$ALTERNATIVE_CHANNEL"
                log "✓ Updated subscription to channel: $CHANNEL"
                sleep 3
            fi
        fi
    fi
    
    # Check if issue persists
    SUBSCRIPTION_MESSAGE=$($KUBECTL_CMD get subscription compliance-operator -n openshift-compliance -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || echo "")
    if echo "$SUBSCRIPTION_MESSAGE" | grep -qi "constraints not satisfiable\|no operators found in channel"; then
        error "Subscription failed with channel error. Available channels: ${AVAILABLE_CHANNELS:-unknown}. Please check: oc get packagemanifest compliance-operator -n openshift-marketplace -o yaml"
    fi
fi

# Step 5: Optional but recommended - Speed up the pull by enabling the default global pull secret
log ""
log "Step 5: Configuring namespace for faster image pulls..."
if ! $KUBECTL_CMD patch namespace openshift-compliance -p '{"metadata":{"annotations":{"openshift.io/node-selector":""}}}' 2>/dev/null; then
    warning "Failed to patch namespace node-selector (non-critical)"
else
    log "✓ Patched namespace node-selector"
fi
if ! $KUBECTL_CMD annotate namespace openshift-compliance openshift.io/sa.scc.supplemental-groups=1000680000/10000 --overwrite 2>/dev/null; then
    warning "Failed to annotate namespace (non-critical)"
else
    log "✓ Annotated namespace"
fi

# Step 6: Wait ~60-90 seconds and verify everything came up cleanly
log ""
log "Step 6: Waiting for installation (60-90 seconds)..."
log "Watching install progress..."
log ""

# Wait for CSV to be created
MAX_WAIT=90
WAIT_COUNT=0
CSV_CREATED=false

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if $KUBECTL_CMD get csv -n openshift-compliance 2>/dev/null | grep -q compliance-operator; then
        CSV_CREATED=true
        log "✓ CSV created"
        break
    fi
    
    # Show progress every 10 seconds
    if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
        $KUBECTL_CMD get csv,subscription,installplan -n openshift-compliance 2>/dev/null | head -5 || true
        log ""
    fi
    
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ "$CSV_CREATED" = false ]; then
    warning "CSV not created after ${MAX_WAIT} seconds. Current status:"
    $KUBECTL_CMD get csv,subscription,installplan -n openshift-compliance
    error "CSV not created. Check subscription status: oc get subscription compliance-operator -n openshift-compliance"
fi

# Get the CSV name
CSV_NAME=$($KUBECTL_CMD get csv -n openshift-compliance -o name 2>/dev/null | grep compliance-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
if [ -z "$CSV_NAME" ]; then
    CSV_NAME=$($KUBECTL_CMD get csv -n openshift-compliance -l operators.coreos.com/compliance-operator.openshift-compliance -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
if [ -z "$CSV_NAME" ]; then
    error "Failed to find CSV name for compliance-operator"
fi

# Wait for CSV to be in Succeeded phase
log "Waiting for CSV to reach Succeeded phase..."
if ! $KUBECTL_CMD wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n openshift-compliance --timeout=300s 2>/dev/null; then
    CSV_STATUS=$($KUBECTL_CMD get csv "$CSV_NAME" -n openshift-compliance -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    warning "CSV did not reach Succeeded phase within timeout. Current status: $CSV_STATUS"
    log "Checking CSV details..."
    $KUBECTL_CMD get csv "$CSV_NAME" -n openshift-compliance
else
    log "✓ CSV is in Succeeded phase"
fi

# Step 7: Final check – you want PHASE: Succeeded and pods Running
log ""
log "Step 7: Final check - verifying CSV and pods..."
log ""
log "CSV status:"
$KUBECTL_CMD get csv -n openshift-compliance
log ""
log "Pod status:"
$KUBECTL_CMD get pods -n openshift-compliance
log ""

# Step 8: Verify final status
log "Step 8: Final verification..."
log ""

CSV_PHASE=$($KUBECTL_CMD get csv "$CSV_NAME" -n openshift-compliance -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
POD_STATUS=$($KUBECTL_CMD get pods -n openshift-compliance -l name=compliance-operator -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")

if [ "$CSV_PHASE" = "Succeeded" ]; then
    log "✓ CSV Phase: Succeeded"
else
    warning "CSV Phase: $CSV_PHASE (expected: Succeeded)"
fi

if echo "$POD_STATUS" | grep -q "Running"; then
    RUNNING_COUNT=$(echo "$POD_STATUS" | grep -o "Running" | wc -l | tr -d '[:space:]')
    log "✓ Found $RUNNING_COUNT Running pod(s)"
else
    warning "No Running pods found. Status: $POD_STATUS"
fi

log ""
log "========================================================="
log "Compliance Operator installation completed!"
log "========================================================="
log "Cluster: aws-us"
log "Namespace: openshift-compliance"
log "Operator: compliance-operator"
log "CSV: $CSV_NAME"
log "CSV Phase: $CSV_PHASE"
log "========================================================="
log ""
