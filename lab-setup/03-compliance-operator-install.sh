#!/bin/bash
# Red Hat Compliance Operator — checks local-cluster and aws-us (if present), installs only where needed.
# Optional: TARGET_CLUSTER_CONTEXT=aws-us limits to a single cluster (legacy callers).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[COMPLIANCE-OP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[COMPLIANCE-OP]${NC} $1"
}

error() {
    echo -e "${RED}[COMPLIANCE-OP] ERROR:${NC} $1" >&2
    echo -e "${RED}[COMPLIANCE-OP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

context_exists() {
    oc config get-contexts -o name 2>/dev/null | sed 's|^context/||' | grep -qx "$1"
}

save_to_bashrc() {
    local var_name="$1"
    local var_value="$2"
    if [ -f ~/.bashrc ]; then
        sed -i "/^export ${var_name}=/d" ~/.bashrc
    fi
    echo "export ${var_name}=\"${var_value}\"" >> ~/.bashrc
    export "${var_name}=${var_value}"
}

compliance_operator_ready() {
    local ns=openshift-compliance
    oc get namespace "$ns" >/dev/null 2>&1 || return 1
    oc get subscription.operators.coreos.com compliance-operator -n "$ns" >/dev/null 2>&1 || return 1
    local csv
    csv=$(oc get subscription.operators.coreos.com compliance-operator -n "$ns" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)
    [ -n "$csv" ] || return 1
    local phase
    phase=$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    [ "$phase" = "Succeeded" ] && return 0
    return 1
}

validate_cluster_prereqs() {
    log "Validating prerequisites for $(oc config current-context 2>/dev/null || echo '?')..."
    if ! oc whoami &>/dev/null; then
        error "OpenShift CLI not connected. Please login with: oc login"
    fi
    log "✓ OpenShift CLI connected as: $(oc whoami)"
    if ! oc auth can-i create subscriptions --all-namespaces &>/dev/null; then
        error "Cluster admin privileges required to install operators. Current user: $(oc whoami)"
    fi
    log "✓ Cluster admin privileges confirmed"
}

install_compliance_operator_core() {
    log ""
    log "========================================================="
    log "Installing Red Hat Compliance Operator"
    log "========================================================="
    log ""
    log "Following idempotent installation steps (safe to run multiple times)..."
    log ""

    log "Step 1: Creating namespace openshift-compliance..."
    if ! oc create ns openshift-compliance --dry-run=client -o yaml | oc apply -f -; then
        error "Failed to create openshift-compliance namespace"
    fi
    log "✓ Namespace created successfully"

    log ""
    log "Step 2: Creating OperatorGroup with AllNamespaces mode..."
    if ! cat <<EOF | oc apply -f -
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

    log ""
    log "Step 3: Determining available channel for compliance-operator..."

    log "Waiting for catalog source to be ready..."
    CATALOG_READY=false
    for i in {1..12}; do
        if oc get catalogsource redhat-operators -n openshift-marketplace >/dev/null 2>&1; then
            CATALOG_STATUS=$(oc get catalogsource redhat-operators -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
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

    log "Checking available channels for compliance-operator..."
    CHANNEL=""
    if oc get packagemanifest compliance-operator -n openshift-marketplace >/dev/null 2>&1; then
        AVAILABLE_CHANNELS=$(oc get packagemanifest compliance-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")

        if [ -n "$AVAILABLE_CHANNELS" ]; then
            log "Available channels: $AVAILABLE_CHANNELS"
            PREFERRED_CHANNELS=("stable" "release-1.8" "release-1.7" "release-1.6" "release-1.5")

            for pref_channel in "${PREFERRED_CHANNELS[@]}"; do
                if echo "$AVAILABLE_CHANNELS" | grep -q "\b$pref_channel\b"; then
                    CHANNEL="$pref_channel"
                    log "✓ Selected channel: $CHANNEL"
                    break
                fi
            done

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

    if [ -z "$CHANNEL" ]; then
        CHANNEL="stable"
        log "Using default channel: $CHANNEL (contains v1.8.0, will verify after subscription creation)"
    fi

    log ""
    log "Step 4: Creating Subscription..."
    log "  Channel: $CHANNEL"
    log "  Source: redhat-operators"
    log "  SourceNamespace: openshift-marketplace"

    if ! cat <<EOF | oc apply -f -
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
        error "Failed to create Subscription"
    fi
    log "✓ Subscription created successfully"

    log "Verifying subscription..."
    sleep 3

    SUBSCRIPTION_MESSAGE=$(oc get subscription compliance-operator -n openshift-compliance -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || echo "")

    if echo "$SUBSCRIPTION_MESSAGE" | grep -qi "constraints not satisfiable\|no operators found in channel"; then
        warning "Channel '$CHANNEL' may not be available. Checking for alternative channels..."

        if oc get packagemanifest compliance-operator -n openshift-marketplace >/dev/null 2>&1; then
            AVAILABLE_CHANNELS=$(oc get packagemanifest compliance-operator -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
            if [ -n "$AVAILABLE_CHANNELS" ]; then
                ALTERNATIVE_CHANNEL=""
                if echo "$AVAILABLE_CHANNELS" | grep -q "\bstable\b"; then
                    ALTERNATIVE_CHANNEL="stable"
                else
                    ALTERNATIVE_CHANNEL=$(echo "$AVAILABLE_CHANNELS" | awk '{print $1}')
                fi

                if [ -n "$ALTERNATIVE_CHANNEL" ] && [ "$ALTERNATIVE_CHANNEL" != "$CHANNEL" ]; then
                    log "Updating subscription to use channel: $ALTERNATIVE_CHANNEL"
                    oc patch subscription compliance-operator -n openshift-compliance --type merge -p "{\"spec\":{\"channel\":\"$ALTERNATIVE_CHANNEL\"}}" || warning "Failed to update channel"
                    CHANNEL="$ALTERNATIVE_CHANNEL"
                    log "✓ Updated subscription to channel: $CHANNEL"
                    sleep 3
                fi
            fi
        fi

        SUBSCRIPTION_MESSAGE=$(oc get subscription compliance-operator -n openshift-compliance -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || echo "")
        if echo "$SUBSCRIPTION_MESSAGE" | grep -qi "constraints not satisfiable\|no operators found in channel"; then
            error "Subscription failed with channel error. Available channels: ${AVAILABLE_CHANNELS:-unknown}. Please check: oc get packagemanifest compliance-operator -n openshift-marketplace -o yaml"
        fi
    fi

    log ""
    log "Step 5: Configuring namespace for faster image pulls..."
    if ! oc patch namespace openshift-compliance -p '{"metadata":{"annotations":{"openshift.io/node-selector":""}}}' 2>/dev/null; then
        warning "Failed to patch namespace node-selector (non-critical)"
    else
        log "✓ Patched namespace node-selector"
    fi
    if ! oc annotate namespace openshift-compliance openshift.io/sa.scc.supplemental-groups=1000680000/10000 --overwrite 2>/dev/null; then
        warning "Failed to annotate namespace (non-critical)"
    else
        log "✓ Annotated namespace"
    fi

    log ""
    log "Waiting for installation (60-90 seconds)..."
    log "Watching install progress..."
    log ""

    MAX_WAIT=90
    WAIT_COUNT=0
    CSV_CREATED=false

    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        if oc get csv -n openshift-compliance 2>/dev/null | grep -q compliance-operator; then
            CSV_CREATED=true
            log "✓ CSV created"
            break
        fi

        if [ $((WAIT_COUNT % 10)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
            log "  Progress check (${WAIT_COUNT}s/${MAX_WAIT}s):"
            oc get csv,subscription,installplan -n openshift-compliance 2>/dev/null | head -5 || true
            log ""
        fi

        sleep 1
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done

    if [ "$CSV_CREATED" = false ]; then
        warning "CSV not created after ${MAX_WAIT} seconds. Current status:"
        oc get csv,subscription,installplan -n openshift-compliance
        error "CSV not created. Check subscription status: oc get subscription compliance-operator -n openshift-compliance"
    fi

    CSV_NAME=$(oc get csv -n openshift-compliance -o name 2>/dev/null | grep compliance-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n openshift-compliance -l operators.coreos.com/compliance-operator.openshift-compliance -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [ -z "$CSV_NAME" ]; then
        error "Failed to find CSV name for compliance-operator"
    fi

    log "Waiting for CSV to reach Succeeded phase..."
    if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n openshift-compliance --timeout=300s 2>/dev/null; then
        CSV_STATUS=$(oc get csv "$CSV_NAME" -n openshift-compliance -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        warning "CSV did not reach Succeeded phase within timeout. Current status: $CSV_STATUS"
        log "Checking CSV details..."
        oc get csv "$CSV_NAME" -n openshift-compliance
    else
        log "✓ CSV is in Succeeded phase"
    fi

    log ""
    log "Final check - verifying CSV and pods..."
    log ""
    log "CSV status:"
    oc get csv -n openshift-compliance
    log ""
    log "Pod status:"
    oc get pods -n openshift-compliance
    log ""

    CSV_PHASE=$(oc get csv "$CSV_NAME" -n openshift-compliance -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    POD_STATUS=$(oc get pods -n openshift-compliance -l name=compliance-operator -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")

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
    log "Namespace: openshift-compliance"
    log "Operator: compliance-operator"
    log "CSV: $CSV_NAME"
    log "CSV Phase: $CSV_PHASE"
    log "========================================================="
}

restart_rhacs_sensor() {
    local ctx_label="${1:-}"
    log ""
    log "Restarting RHACS sensor to sync Compliance Operator results (context: $ctx_label)..."
    local RHACS_NAMESPACE=""
    for ns in stackrox rhacs-operator; do
        if oc get deployment sensor -n "$ns" &>/dev/null 2>&1; then
            RHACS_NAMESPACE="$ns"
            break
        fi
    done

    if oc whoami &>/dev/null 2>&1; then
        if [ -n "$RHACS_NAMESPACE" ]; then
            log "Found RHACS sensor in namespace $RHACS_NAMESPACE, restarting sensor pods..."
            if oc delete pods -l app.kubernetes.io/component=sensor -n "$RHACS_NAMESPACE" &>/dev/null 2>&1; then
                log "✓ Sensor pods deleted, waiting for restart..."
                if oc wait --for=condition=Available deployment/sensor -n "$RHACS_NAMESPACE" --timeout=120s &>/dev/null 2>&1; then
                    log "✓ Sensor pods restarted successfully"
                else
                    warning "Sensor pods restarted but may not be fully ready yet"
                fi
            else
                warning "Could not restart sensor pods (may not exist yet or already restarting)"
            fi
        else
            log "RHACS sensor not found in stackrox or rhacs-operator on this cluster, skipping sensor restart"
        fi
    fi
    log ""
}

ensure_bashrc_lab_paths() {
    log ""
    log "Updating shell profile with SCRIPT_DIR / PROJECT_ROOT (for other lab steps)..."
    if [ ! -f ~/.bashrc ]; then
        touch ~/.bashrc
    fi
    if grep -q "^source $" ~/.bashrc 2>/dev/null; then
        sed -i '/^source $/d' ~/.bashrc
    fi
    save_to_bashrc "SCRIPT_DIR" "$SCRIPT_DIR"
    save_to_bashrc "PROJECT_ROOT" "$PROJECT_ROOT"
    log "✓ SCRIPT_DIR=$SCRIPT_DIR"
    log "✓ PROJECT_ROOT=$PROJECT_ROOT"
}

# --- main ---

if ! command -v oc >/dev/null 2>&1; then
    error "oc not found"
fi

if [ -n "${TARGET_CLUSTER_CONTEXT:-}" ]; then
    TARGET_CONTEXTS=("$TARGET_CLUSTER_CONTEXT")
else
    TARGET_CONTEXTS=(local-cluster)
    if context_exists aws-us; then
        TARGET_CONTEXTS+=(aws-us)
    else
        log "No aws-us context in kubeconfig; only checking local-cluster"
    fi
fi

ORIGINAL_CONTEXT=$(oc config current-context 2>/dev/null || true)

log "========================================================="
log "Compliance Operator — contexts to check: ${TARGET_CONTEXTS[*]}"
log "========================================================="
log "For each context: detect existing install first; install only if needed."

for ctx in "${TARGET_CONTEXTS[@]}"; do
    log ""
    log "──────── Context: $ctx ────────"
    if ! oc config use-context "$ctx" >/dev/null 2>&1; then
        warning "Cannot switch to context '$ctx' — skipping"
        continue
    fi
    log "Checking if Compliance Operator is already installed (CSV Succeeded)..."
    if compliance_operator_ready; then
        log "✓ Compliance Operator already installed and healthy — skipping install on $ctx"
        continue
    fi
    log "Compliance Operator not installed or not healthy on $ctx — running install..."
    validate_cluster_prereqs
    install_compliance_operator_core
    restart_rhacs_sensor "$ctx"
done

ensure_bashrc_lab_paths

if [ -n "${ORIGINAL_CONTEXT:-}" ]; then
    oc config use-context "$ORIGINAL_CONTEXT" >/dev/null 2>&1 || true
fi

log ""
log "========================================================="
log "Compliance Operator pass complete for: ${TARGET_CONTEXTS[*]}"
log "========================================================="
