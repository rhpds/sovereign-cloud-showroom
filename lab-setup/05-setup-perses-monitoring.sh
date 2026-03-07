#!/bin/bash
# Perses Monitoring Setup Script
# Installs Cluster Observability Operator and configures Perses monitoring

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[PERSES-MONITORING]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[PERSES-MONITORING]${NC} $1"
}

error() {
    echo -e "${RED}[PERSES-MONITORING] ERROR:${NC} $1" >&2
    echo -e "${RED}[PERSES-MONITORING] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Set up script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
MONITORING_SETUP_DIR="$PROJECT_ROOT/monitoring-setup"

# Set namespace to rhacs-operator (as requested)
NAMESPACE="rhacs-operator"
OPERATOR_NAMESPACE="openshift-cluster-observability-operator"

# Prerequisites validation
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
log "Using namespace: $NAMESPACE"

# Step 0: Check if everything is already installed
log ""
log "========================================================="
log "Step 0: Checking if Cluster Observability Operator and monitoring resources are already installed"
log "========================================================="

ALREADY_INSTALLED=true

# Check if Cluster Observability Operator is installed and running
log "Checking Cluster Observability Operator status..."
if oc get namespace $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
        CURRENT_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        if [ -n "$CURRENT_CSV" ] && [ "$CURRENT_CSV" != "null" ]; then
            # Check if CSV actually exists before trying to get its phase
            if oc get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
                CSV_PHASE=$(oc get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$CSV_PHASE" = "Succeeded" ]; then
                    log "✓ Cluster Observability Operator is installed and running (CSV: $CURRENT_CSV)"
                else
                    log "  Cluster Observability Operator CSV is in phase: $CSV_PHASE (not Succeeded)"
                    ALREADY_INSTALLED=false
                fi
            else
                log "  Cluster Observability Operator subscription references CSV '$CURRENT_CSV' but CSV does not exist yet"
                ALREADY_INSTALLED=false
            fi
        else
            log "  Cluster Observability Operator subscription exists but CSV not determined"
            ALREADY_INSTALLED=false
        fi
    else
        log "  Cluster Observability Operator subscription not found"
        ALREADY_INSTALLED=false
    fi
else
    log "  Cluster Observability Operator namespace not found"
    ALREADY_INSTALLED=false
fi

# Check if key monitoring resources are installed
if [ "$ALREADY_INSTALLED" = true ]; then
    log "Checking monitoring resources..."
    
    # Check MonitoringStack
    if oc get monitoringstack rhacs-monitoring-stack -n $NAMESPACE >/dev/null 2>&1; then
        log "✓ MonitoringStack (rhacs-monitoring-stack) exists"
    else
        log "  MonitoringStack (rhacs-monitoring-stack) not found"
        ALREADY_INSTALLED=false
    fi
    
    # Check ScrapeConfig
    if oc get scrapeconfig rhacs-scrape-config -n $NAMESPACE >/dev/null 2>&1; then
        log "✓ ScrapeConfig (rhacs-scrape-config) exists"
    else
        log "  ScrapeConfig (rhacs-scrape-config) not found"
        ALREADY_INSTALLED=false
    fi
    
    # Check Prometheus
    if oc get prometheus rhacs-prometheus-server -n $NAMESPACE >/dev/null 2>&1; then
        log "✓ Prometheus (rhacs-prometheus-server) exists"
    else
        log "  Prometheus (rhacs-prometheus-server) not found"
        ALREADY_INSTALLED=false
    fi
    
    # Check Perses Datasource
    if oc get datasource rhacs-datasource -n $NAMESPACE >/dev/null 2>&1; then
        log "✓ Perses Datasource (rhacs-datasource) exists"
    else
        log "  Perses Datasource (rhacs-datasource) not found"
        ALREADY_INSTALLED=false
    fi
fi

# If everything is installed, skip to the end
if [ "$ALREADY_INSTALLED" = true ]; then
    log ""
    log "========================================================="
    log "✓ All components are already installed!"
    log "Skipping installation and proceeding to final summary..."
    log "========================================================="
    log ""
    SKIP_INSTALLATION=true
else
    log ""
    log "Not all components are installed. Proceeding with installation..."
    SKIP_INSTALLATION=false
fi

# Step 0: Generate TLS certificate for RHACS Prometheus monitoring stack
if [ "$SKIP_INSTALLATION" = false ]; then
log ""
log "========================================================="
log "Step 0: Generating TLS certificate for RHACS Prometheus"
log "========================================================="

# Check if openssl is available
if ! command -v openssl &>/dev/null; then
    error "openssl is required but not found. Please install openssl."
fi
log "✓ openssl found"

# Check if namespace exists
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found. Please ensure RHACS is installed first."
fi
log "✓ Namespace '$NAMESPACE' exists"

# Generate a private key and certificate
log "Generating TLS private key and certificate..."
CERT_CN="sample-rhacs-operator-prometheus.$NAMESPACE.svc"
if openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=$CERT_CN" \
        -keyout tls.key -out tls.crt 2>/dev/null; then
    log "✓ TLS certificate generated successfully"
    log "  Subject: $CERT_CN"
else
    error "Failed to generate TLS certificate"
fi

# Always delete existing TLS secret to avoid certificate mixups
log "Deleting existing TLS secret 'sample-rhacs-operator-prometheus-tls' if it exists..."
oc delete secret sample-rhacs-operator-prometheus-tls -n "$NAMESPACE" 2>/dev/null && log "  Deleted existing secret" || log "  No existing secret found"

# Create TLS secret in the namespace
log "Creating TLS secret 'sample-rhacs-operator-prometheus-tls' in namespace '$NAMESPACE'..."
if oc create secret tls sample-rhacs-operator-prometheus-tls --cert=tls.crt --key=tls.key -n "$NAMESPACE" 2>/dev/null; then
    log "✓ TLS secret created successfully"
else
    error "Failed to create TLS secret"
fi

# Create UserPKI auth provider in RHACS for Prometheus
log "Creating UserPKI auth provider in RHACS for Prometheus..."

# Generate ROX_ENDPOINT from Central route
log "Extracting ROX_ENDPOINT from Central route..."
CENTRAL_ROUTE=$(oc get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_ROUTE" ]; then
    warning "Central route not found in namespace '$NAMESPACE'. Skipping auth provider creation."
    warning "You may need to create the UserPKI auth provider manually later."
    ROX_ENDPOINT=""
else
    ROX_ENDPOINT="$CENTRAL_ROUTE"
    log "✓ Extracted ROX_ENDPOINT: $ROX_ENDPOINT"
fi

# Generate ROX_API_TOKEN if ROX_ENDPOINT is available
ROX_API_TOKEN=""
if [ -n "$ROX_ENDPOINT" ]; then
    log "Generating API token..."
    
    # Get ADMIN_PASSWORD from secret
    ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
    if [ -z "$ADMIN_PASSWORD_B64" ]; then
        warning "Admin password secret 'central-htpasswd' not found in namespace '$NAMESPACE'. Skipping auth provider creation."
        ROX_ENDPOINT=""
    else
        ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
        if [ -z "$ADMIN_PASSWORD" ]; then
            warning "Failed to decode admin password from secret. Skipping auth provider creation."
            ROX_ENDPOINT=""
        else
            # Generate API token
            ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT#https://}"
            ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"
            
            set +e
            TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
                -u "admin:${ADMIN_PASSWORD}" \
                -H "Content-Type: application/json" \
                "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
                -d '{"name":"perses-monitoring-script-token","roles":["Admin"]}' 2>&1)
            TOKEN_CURL_EXIT_CODE=$?
            set -e
            
            if [ $TOKEN_CURL_EXIT_CODE -eq 0 ]; then
                # Extract token from response
                if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
                    ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "")
                fi
                
                if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ]; then
                    ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
                fi
                
                if [ -z "$ROX_API_TOKEN" ]; then
                    warning "Failed to extract API token from response. Skipping auth provider creation."
                    ROX_ENDPOINT=""
                else
                    log "✓ API token generated (length: ${#ROX_API_TOKEN} chars)"
                fi
            else
                warning "Failed to generate API token. curl exit code: $TOKEN_CURL_EXIT_CODE. Skipping auth provider creation."
                ROX_ENDPOINT=""
            fi
        fi
    fi
fi

if [ -n "$ROX_ENDPOINT" ] && [ -n "$ROX_API_TOKEN" ]; then
    # Check if roxctl is available
    if ! command -v roxctl &>/dev/null; then
        log "roxctl not found, checking if it needs to be installed..."
        # Try to install roxctl (similar to script 01)
        if command -v curl &>/dev/null; then
            log "Downloading roxctl..."
            curl -L -f -o /tmp/roxctl "https://mirror.openshift.com/pub/rhacs/assets/4.8.3/bin/Linux/roxctl" 2>/dev/null || {
                warning "Failed to download roxctl. Skipping auth provider creation."
                warning "You may need to create the UserPKI auth provider manually later."
                ROX_ENDPOINT=""
            }
            if [ -f /tmp/roxctl ]; then
                chmod +x /tmp/roxctl
                ROXCTL_CMD="/tmp/roxctl"
                log "✓ roxctl downloaded to /tmp/roxctl"
            fi
        else
            warning "curl not found. Cannot download roxctl. Skipping auth provider creation."
            ROX_ENDPOINT=""
        fi
    else
        ROXCTL_CMD="roxctl"
        log "✓ roxctl found in PATH"
    fi
    
    if [ -n "$ROX_ENDPOINT" ] && [ -n "$ROXCTL_CMD" ]; then
        # Normalize ROX_ENDPOINT for roxctl (add :443 if no port specified)
        ROX_ENDPOINT_NORMALIZED="$ROX_ENDPOINT"
        if [[ ! "$ROX_ENDPOINT_NORMALIZED" =~ :[0-9]+$ ]]; then
            ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED}:443"
        fi
        
        # Remove https:// prefix if present
        ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED#https://}"
        ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED#http://}"
        
        # Export ROX_API_TOKEN so roxctl can use it as an environment variable
        export ROX_API_TOKEN
        
        # Always delete existing auth provider to avoid certificate mixups
        log "Deleting existing UserPKI auth provider 'Prometheus' if it exists..."
        # Temporarily disable ERR trap since delete may fail if provider doesn't exist (which is okay)
        set +e
        trap '' ERR
        # Use printf to send "y\n" (yes with newline) to answer the interactive confirmation prompt
        # Use timeout to prevent hanging if the command doesn't respond
        # Add || true to prevent non-zero exit code from causing issues
        DELETE_OUTPUT=$(timeout 30 bash -c "export ROX_API_TOKEN=\"$ROX_API_TOKEN\"; printf 'y\n' | $ROXCTL_CMD -e \"$ROX_ENDPOINT_NORMALIZED\" \
            central userpki delete Prometheus \
            --insecure-skip-tls-verify 2>&1" 2>&1 || true)
        DELETE_EXIT_CODE=$?
        # Re-enable ERR trap
        trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR
        set -e
        
        # Check if deletion was successful
        # Note: "context canceled" error is actually a false alarm - deletion succeeds despite this error
        if echo "$DELETE_OUTPUT" | grep -qi "context canceled\|Canceled"; then
            # Context canceled error means deletion actually succeeded
            log "✓ Deleted existing UserPKI auth provider 'Prometheus' (context canceled is expected)"
        elif echo "$DELETE_OUTPUT" | grep -qi "deleted\|success\|Deleting provider"; then
            log "✓ Deleted existing UserPKI auth provider 'Prometheus'"
        elif echo "$DELETE_OUTPUT" | grep -qi "not found\|does not exist\|No user certificate providers"; then
            log "No existing UserPKI auth provider 'Prometheus' found (this is okay)"
        elif [ $DELETE_EXIT_CODE -eq 0 ]; then
            log "✓ Delete command completed successfully"
        else
            # Even if exit code is non-zero, check if provider was actually deleted
            log "Delete command completed with exit code $DELETE_EXIT_CODE. Output: ${DELETE_OUTPUT:0:200}"
            log "Continuing with creation (provider may have been deleted anyway)..."
        fi
        
        # Create new auth provider
        log "Creating UserPKI auth provider 'Prometheus' with Admin role..."
        
        # Verify certificate file exists
        if [ ! -f "tls.crt" ]; then
            error "Certificate file 'tls.crt' not found in current directory. Cannot create UserPKI auth provider."
        fi
        log "✓ Certificate file 'tls.crt' found"
        
        # Verify ROX_API_TOKEN is set
        if [ -z "$ROX_API_TOKEN" ]; then
            error "ROX_API_TOKEN is required for roxctl authentication but is not set."
        fi
        
        # Temporarily disable ERR trap to handle errors manually
        set +e
        trap '' ERR
        
        AUTH_PROVIDER_OUTPUT=$(ROX_API_TOKEN="$ROX_API_TOKEN" $ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
            central userpki create Prometheus \
            -c tls.crt \
            -r Admin \
            --insecure-skip-tls-verify 2>&1)
        AUTH_PROVIDER_EXIT_CODE=$?
        
        # Re-enable ERR trap
        trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR
        set -e
        
        if [ $AUTH_PROVIDER_EXIT_CODE -eq 0 ]; then
            log "✓ UserPKI auth provider 'Prometheus' created successfully"
        else
            # Check if it's because it already exists (might have been created between delete and create)
            if echo "$AUTH_PROVIDER_OUTPUT" | grep -qi "already exists\|duplicate"; then
                warning "Auth provider still exists after deletion attempt. Output: ${AUTH_PROVIDER_OUTPUT:0:300}"
                warning "You may need to delete it manually: ROX_API_TOKEN=\"\$ROX_API_TOKEN\" roxctl -e $ROX_ENDPOINT_NORMALIZED central userpki list --insecure-skip-tls-verify"
            else
                error "Failed to create UserPKI auth provider. Exit code: $AUTH_PROVIDER_EXIT_CODE. Output: ${AUTH_PROVIDER_OUTPUT:0:500}"
            fi
        fi
    fi
fi

# Clean up temporary certificate files
rm -f tls.key tls.crt
log "✓ Temporary certificate files cleaned up"
fi  # End of SKIP_INSTALLATION check for TLS certificate generation

OPERATOR_NAMESPACE="openshift-cluster-observability-operator"

# Step 0: Check if everything is already installed
log ""
log "========================================================="
log "Step 0: Checking if Cluster Observability Operator and monitoring resources are already installed"
log "========================================================="

ALREADY_INSTALLED=true

# Check if Cluster Observability Operator is installed and running
log "Checking Cluster Observability Operator status..."
if oc get namespace $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
        CURRENT_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        if [ -n "$CURRENT_CSV" ] && [ "$CURRENT_CSV" != "null" ]; then
            # Check if CSV actually exists before trying to get its phase
            if oc get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
                CSV_PHASE=$(oc get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$CSV_PHASE" = "Succeeded" ]; then
                    log "✓ Cluster Observability Operator is installed and running (CSV: $CURRENT_CSV)"
                else
                    log "  Cluster Observability Operator CSV is in phase: $CSV_PHASE (not Succeeded)"
                    ALREADY_INSTALLED=false
                fi
            else
                log "  Cluster Observability Operator subscription references CSV '$CURRENT_CSV' but CSV does not exist yet"
                ALREADY_INSTALLED=false
            fi
        else
            log "  Cluster Observability Operator subscription exists but CSV not determined"
            ALREADY_INSTALLED=false
        fi
    else
        log "  Cluster Observability Operator subscription not found"
        ALREADY_INSTALLED=false
    fi
else
    log "  Cluster Observability Operator namespace not found"
    ALREADY_INSTALLED=false
fi

# Check if key monitoring resources are installed
if [ "$ALREADY_INSTALLED" = true ]; then
    log "Checking monitoring resources..."
    
    # Check MonitoringStack
    if oc get monitoringstack rhacs-monitoring-stack -n $NAMESPACE >/dev/null 2>&1; then
        log "✓ MonitoringStack (rhacs-monitoring-stack) exists"
    else
        log "  MonitoringStack (rhacs-monitoring-stack) not found"
        ALREADY_INSTALLED=false
    fi
    
    # Check ScrapeConfig
    if oc get scrapeconfig rhacs-scrape-config -n $NAMESPACE >/dev/null 2>&1; then
        log "✓ ScrapeConfig (rhacs-scrape-config) exists"
    else
        log "  ScrapeConfig (rhacs-scrape-config) not found"
        ALREADY_INSTALLED=false
    fi
    
    # Check Prometheus
    if oc get prometheus rhacs-prometheus-server -n $NAMESPACE >/dev/null 2>&1; then
        log "✓ Prometheus (rhacs-prometheus-server) exists"
    else
        log "  Prometheus (rhacs-prometheus-server) not found"
        ALREADY_INSTALLED=false
    fi
    
    # Check Perses Datasource
    if oc get datasource rhacs-datasource -n $NAMESPACE >/dev/null 2>&1; then
        log "✓ Perses Datasource (rhacs-datasource) exists"
    else
        log "  Perses Datasource (rhacs-datasource) not found"
        ALREADY_INSTALLED=false
    fi
fi

# If everything is installed, skip to the end
if [ "$ALREADY_INSTALLED" = true ]; then
    log ""
    log "========================================================="
    log "✓ All components are already installed!"
    log "Skipping installation and proceeding to final summary..."
    log "========================================================="
    log ""
    SKIP_INSTALLATION=true
else
    log ""
    log "Not all components are installed. Proceeding with installation..."
    SKIP_INSTALLATION=false
fi

# Step 1: Install Cluster Observability Operator
if [ "$SKIP_INSTALLATION" = false ]; then
log ""
log "========================================================="
log "Step 1: Installing Cluster Observability Operator"
log "========================================================="

# Check if Cluster Observability Operator is already installed
log "Checking if Cluster Observability Operator is already installed..."

if oc get namespace $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "Namespace $OPERATOR_NAMESPACE already exists"
    
    # Check for existing subscription
    if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
        CURRENT_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}')
        if [ -z "$CURRENT_CSV" ] || [ "$CURRENT_CSV" = "null" ]; then
            log "Subscription exists but CSV not yet determined, proceeding with installation..."
        else
            # Check if CSV actually exists before trying to get its phase
            if oc get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
                CSV_PHASE=$(oc get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            
                if [ "$CSV_PHASE" = "Succeeded" ]; then
                    log "✓ Cluster Observability Operator is already installed and running"
                    log "  Installed CSV: $CURRENT_CSV"
                    log "  Status: $CSV_PHASE"
                    log "Skipping installation..."
                else
                    log "Cluster Observability Operator subscription exists but CSV is in phase: $CSV_PHASE"
                    log "Continuing with installation to ensure proper setup..."
                fi
            else
                log "Subscription references CSV '$CURRENT_CSV' but CSV does not exist yet, proceeding with installation..."
            fi
        fi
    else
        log "Namespace exists but no subscription found, proceeding with installation..."
    fi
else
    log "Cluster Observability Operator not found, proceeding with installation..."
fi

# Function to force delete namespace stuck in Terminating state
force_delete_stuck_namespace() {
    local namespace=$1
    
    if oc get namespace "$namespace" &>/dev/null 2>&1; then
        NS_PHASE=$(oc get namespace "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$NS_PHASE" = "Terminating" ]; then
            warning "Namespace $namespace is stuck in Terminating state - force deleting..."
            
            # Get current finalizers (finalizers are in metadata, not spec)
            FINALIZERS_JSON=$(oc get namespace "$namespace" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || echo "[]")
            
            # Check if there are finalizers
            if [ "$FINALIZERS_JSON" != "[]" ] && [ -n "$FINALIZERS_JSON" ]; then
                FINALIZERS_LIST=$(oc get namespace "$namespace" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
                log "  Removing finalizers: $FINALIZERS_LIST"
                
                # Try to replace finalizers with empty array using merge patch
                if oc patch namespace "$namespace" --type merge -p '{"metadata":{"finalizers":[]}}' &>/dev/null 2>&1; then
                    log "  ✓ Finalizers removed - waiting for namespace deletion to complete..."
                    # Wait for namespace to be deleted (max 60 seconds)
                    for i in {1..12}; do
                        sleep 5
                        if ! oc get namespace "$namespace" &>/dev/null 2>&1; then
                            log "  ✓ Namespace $namespace has been deleted"
                            return 0
                        fi
                    done
                    warning "  Namespace $namespace still exists after removing finalizers (may need more time)"
                    return 0
                else
                    # Try JSON patch as fallback
                    oc patch namespace "$namespace" --type json -p='[{"op": "replace", "path": "/metadata/finalizers", "value": []}]' &>/dev/null 2>&1
                    if [ $? -eq 0 ]; then
                        log "  ✓ Finalizers removed via JSON patch - waiting for namespace deletion..."
                        sleep 10
                        return 0
                    else
                        warning "  Failed to remove finalizers from namespace $namespace"
                        return 1
                    fi
                fi
            else
                log "  No finalizers found - namespace should complete deletion soon"
                # Wait a bit for namespace to finish deleting
                sleep 10
                return 0
            fi
        fi
    fi
    return 0
}

# Check and handle stuck namespace before creating
log "Checking $OPERATOR_NAMESPACE namespace status..."
if oc get namespace $OPERATOR_NAMESPACE &>/dev/null 2>&1; then
    NS_PHASE=$(oc get namespace $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$NS_PHASE" = "Terminating" ]; then
        log "Namespace $OPERATOR_NAMESPACE is stuck in Terminating state"
        force_delete_stuck_namespace "$OPERATOR_NAMESPACE"
        # Wait a moment after force delete attempt
        sleep 5
    fi
fi

# Create namespace for Cluster Observability Operator
log "Creating $OPERATOR_NAMESPACE namespace..."
if ! oc get namespace $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    if ! oc create namespace $OPERATOR_NAMESPACE; then
        error "Failed to create $OPERATOR_NAMESPACE namespace. Check permissions: oc auth can-i create namespace"
    fi
    log "✓ Namespace created successfully"
else
    NS_PHASE=$(oc get namespace $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$NS_PHASE" = "Terminating" ]; then
        error "Namespace $OPERATOR_NAMESPACE is still in Terminating state. Please run cleanup script first: ./cleanup/cleanup-all.sh"
    fi
    log "✓ Namespace already exists"
fi

# Verify namespace exists and we have access
if ! oc get namespace $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    error "Cannot access namespace $OPERATOR_NAMESPACE. Check permissions."
fi
log "✓ Namespace verified and accessible"

# Cleanup: Delete wrong OperatorGroup and Subscription if they exist
log ""
log "========================================================="
log "Cleanup: Removing incorrect OperatorGroup and Subscription"
log "========================================================="

# Check for existing OperatorGroups and delete wrong ones
log "Checking for existing OperatorGroups..."
EXISTING_OGS=$(oc get operatorgroup -n $OPERATOR_NAMESPACE -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "$EXISTING_OGS" ]; then
    for og_name in $EXISTING_OGS; do
        log "  Found OperatorGroup: $og_name"
        # Delete if it's not the correct one (cluster-observability-og)
        if [ "$og_name" != "cluster-observability-og" ]; then
            log "  Deleting incorrect OperatorGroup: $og_name"
            oc delete operatorgroup $og_name -n $OPERATOR_NAMESPACE 2>/dev/null && log "    ✓ Deleted" || log "    (may not exist or already deleted)"
        fi
    done
else
    log "  No existing OperatorGroups found"
fi

# Delete stuck Subscription (it will be recreated correctly)
log "Checking for existing Subscription..."
if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "  Deleting existing Subscription (will be recreated correctly)..."
    oc delete subscription cluster-observability-operator -n $OPERATOR_NAMESPACE 2>/dev/null && log "    ✓ Deleted" || log "    (may not exist or already deleted)"
    # Wait a moment for deletion to complete
    sleep 3
else
    log "  No existing Subscription found"
fi

# Create proper OperatorGroup that supports global operators
log ""
log "Creating proper OperatorGroup with AllNamespaces mode..."
if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-og
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces: []   # empty list = AllNamespaces mode (required for COO)
EOF
then
    error "Failed to create OperatorGroup"
fi
log "✓ OperatorGroup created successfully (AllNamespaces mode)"
# Wait for OperatorGroup to be ready
log "Waiting for OperatorGroup to be ready..."
sleep 5

# Verify OperatorGroup exists and is ready
if ! oc get operatorgroup -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    error "OperatorGroup not found after creation. Check namespace permissions."
fi
log "✓ OperatorGroup verified"

# Verify catalog source is ready before creating subscription
log "Checking catalog source availability..."
CATALOG_SOURCE_READY=false
for i in {1..12}; do
    if oc get catalogsource redhat-operators -n openshift-marketplace >/dev/null 2>&1; then
        CATALOG_STATUS=$(oc get catalogsource redhat-operators -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        if [ "$CATALOG_STATUS" = "READY" ]; then
            CATALOG_SOURCE_READY=true
            log "✓ Catalog source 'redhat-operators' is READY"
            break
        else
            log "  Catalog source status: ${CATALOG_STATUS:-unknown} (waiting for READY...)"
        fi
    else
        log "  Catalog source 'redhat-operators' not found (attempt $i/12)"
    fi
    if [ $i -lt 12 ]; then
        sleep 5
    fi
done

if [ "$CATALOG_SOURCE_READY" = false ]; then
    warning "Catalog source may not be ready, but continuing..."
fi

# Verify operator is available in catalog before creating subscription
log "Checking if cluster-observability-operator is available in catalog..."
if ! oc get packagemanifest cluster-observability-operator -n openshift-marketplace >/dev/null 2>&1; then
    warning "Operator not found in catalog. Checking available operators..."
    oc get packagemanifest -n openshift-marketplace | grep -i observability || log "  No observability operators found"
    warning "cluster-observability-operator not found in openshift-marketplace catalog. This may be normal if catalog is still syncing."
    log "Waiting 30 seconds for catalog to sync..."
    sleep 30
    # Try again
    if ! oc get packagemanifest cluster-observability-operator -n openshift-marketplace >/dev/null 2>&1; then
        error "cluster-observability-operator still not found in openshift-marketplace catalog after waiting. Please ensure the catalog is available."
    fi
fi

# Set channel to stable (the correct channel name for cluster-observability-operator)
CHANNEL="stable"
log "✓ Operator found in catalog. Using channel: $CHANNEL"

# Check if subscription already exists (might have been created via UI)
log "Checking if subscription already exists..."
if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "✓ Subscription already exists (may have been created via UI)"
    EXISTING_SUB_CHANNEL=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    EXISTING_SUB_SOURCE=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.spec.source}' 2>/dev/null || echo "")
    log "  Existing subscription channel: ${EXISTING_SUB_CHANNEL:-unknown}"
    log "  Existing subscription source: ${EXISTING_SUB_SOURCE:-unknown}"
    
    # If channel differs, update it to stable-1.0
    if [ -n "$EXISTING_SUB_CHANNEL" ] && [ "$EXISTING_SUB_CHANNEL" != "$CHANNEL" ]; then
        log "  Updating subscription channel from '$EXISTING_SUB_CHANNEL' to '$CHANNEL'..."
        oc patch subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE --type merge -p "{\"spec\":{\"channel\":\"$CHANNEL\"}}" || warning "Failed to update channel"
        log "✓ Subscription channel updated to $CHANNEL"
    elif [ "$EXISTING_SUB_CHANNEL" = "$CHANNEL" ]; then
        log "✓ Subscription channel is already set to $CHANNEL"
        
        # Check if operator is already installed and running
        EXISTING_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
        if [ -n "$EXISTING_CSV" ] && [ "$EXISTING_CSV" != "null" ]; then
            if oc get csv "$EXISTING_CSV" -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
                CSV_PHASE=$(oc get csv "$EXISTING_CSV" -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$CSV_PHASE" = "Succeeded" ]; then
                    log "✓ Operator is already installed and running (CSV: $EXISTING_CSV)"
                    SKIP_SUBSCRIPTION_WAIT=true
                fi
            fi
        fi
    fi
    SUBSCRIPTION_CREATED=true
else
    # Create Subscription for Cluster Observability Operator
    log ""
    log "Creating Subscription for Cluster Observability Operator..."
    log "  Channel: $CHANNEL"
    log "  Source: redhat-operators"
    log "  SourceNamespace: openshift-marketplace"
    SUBSCRIPTION_CREATED=false
    SKIP_SUBSCRIPTION_WAIT=false
    SUBSCRIPTION_OUTPUT=$(cat <<EOF | oc apply -f - 2>&1
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    )
    SUBSCRIPTION_EXIT_CODE=$?

    if [ $SUBSCRIPTION_EXIT_CODE -eq 0 ]; then
        SUBSCRIPTION_CREATED=true
        log "✓ Subscription creation command succeeded"
        log "  Output: $SUBSCRIPTION_OUTPUT"
    else
        log "Subscription creation command failed with exit code: $SUBSCRIPTION_EXIT_CODE"
        log "  Output: $SUBSCRIPTION_OUTPUT"
        error "Failed to create Subscription. Check output above for details."
    fi
fi

# Wait for OLM to process the subscription and create InstallPlan (only if needed)
if [ "${SKIP_SUBSCRIPTION_WAIT:-false}" != true ]; then
    log "Waiting for OLM to process subscription (this may take 10-30 seconds)..."
    SUBSCRIPTION_PROCESSED=false
    for i in {1..12}; do
        sleep 5
        if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
            # Check if InstallPlan has been created
            INSTALL_PLAN_CHECK=$(oc get installplan -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$INSTALL_PLAN_CHECK" ]; then
                SUBSCRIPTION_PROCESSED=true
                log "✓ Subscription processed and InstallPlan created: $INSTALL_PLAN_CHECK"
                break
            fi
            
            # Also check if CSV already exists (operator may already be installed)
            EXISTING_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
            if [ -n "$EXISTING_CSV" ] && [ "$EXISTING_CSV" != "null" ]; then
                if oc get csv "$EXISTING_CSV" -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
                    CSV_PHASE=$(oc get csv "$EXISTING_CSV" -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                    if [ "$CSV_PHASE" = "Succeeded" ]; then
                        SUBSCRIPTION_PROCESSED=true
                        log "✓ Operator is already installed (CSV: $EXISTING_CSV), skipping InstallPlan wait"
                        break
                    fi
                fi
            fi
        fi
        if [ $((i % 3)) -eq 0 ]; then
            log "  Still waiting for subscription to be processed... ($((i * 5))s elapsed)"
        fi
    done

    if [ "$SUBSCRIPTION_PROCESSED" = false ]; then
        log "Subscription processing is taking longer than expected, continuing anyway..."
    fi
else
    log "✓ Subscription already exists with correct channel and operator is installed, skipping wait"
fi

# Verify subscription was actually created
log "Verifying subscription exists in namespace $OPERATOR_NAMESPACE..."
if ! oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "ERROR: Subscription not found after creation attempt"
    log "Checking all subscriptions in namespace..."
    oc get subscription.operators.coreos.com -n $OPERATOR_NAMESPACE 2>&1 || log "  No subscriptions found in namespace"
    log ""
    log "Checking if subscription exists in other namespaces..."
    oc get subscription.operators.coreos.com cluster-observability-operator --all-namespaces 2>&1 || log "  Subscription not found in any namespace"
    log ""
    log "Checking OperatorGroup..."
    oc get operatorgroup -n $OPERATOR_NAMESPACE 2>&1 || log "  No OperatorGroup found"
    log ""
    log "Checking namespace..."
    oc get namespace $OPERATOR_NAMESPACE 2>&1 || log "  Namespace not found"
    error "Subscription was not created successfully. Check namespace permissions and operator catalog availability."
fi
log "✓ Subscription verified"

# Check subscription status for any immediate issues
log "Checking subscription status..."
SUBSCRIPTION_STATUS=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.state}' 2>/dev/null || echo "")
if [ -n "$SUBSCRIPTION_STATUS" ]; then
    log "  Subscription state: $SUBSCRIPTION_STATUS"
fi

# Check subscription conditions for errors
log "Checking subscription conditions..."
SUBSCRIPTION_CONDITIONS=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
if [ -n "$SUBSCRIPTION_CONDITIONS" ]; then
    for condition in $SUBSCRIPTION_CONDITIONS; do
        CONDITION_STATUS=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath="{.status.conditions[?(@.type==\"$condition\")].status}" 2>/dev/null || echo "")
        CONDITION_MESSAGE=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath="{.status.conditions[?(@.type==\"$condition\")].message}" 2>/dev/null || echo "")
        if [ "$CONDITION_STATUS" = "True" ] || [ "$CONDITION_STATUS" = "False" ]; then
            log "  Condition $condition: $CONDITION_STATUS"
            if [ -n "$CONDITION_MESSAGE" ]; then
                log "    Message: $CONDITION_MESSAGE"
            fi
        fi
    done
fi

# Check for any error messages in subscription status
SUBSCRIPTION_ERROR=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="CatalogSourcesUnhealthy")].message}' 2>/dev/null || echo "")
if [ -n "$SUBSCRIPTION_ERROR" ]; then
    warning "Subscription has catalog source issues: $SUBSCRIPTION_ERROR"
fi

# Check currentCSV and installedCSV
CURRENT_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
INSTALLED_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
if [ -n "$CURRENT_CSV" ]; then
    log "  Current CSV: $CURRENT_CSV"
fi
if [ -n "$INSTALLED_CSV" ]; then
    log "  Installed CSV: $INSTALLED_CSV"
fi

# Check for InstallPlan
log "Checking for InstallPlan..."
INSTALL_PLAN=$(oc get installplan -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$INSTALL_PLAN" ]; then
    INSTALL_PLAN_PHASE=$(oc get installplan $INSTALL_PLAN -n $OPERATOR_NAMESPACE -o jsonpath='{.spec.approved},{.status.phase}' 2>/dev/null || echo "")
    log "  InstallPlan found: $INSTALL_PLAN"
    log "  InstallPlan status: $INSTALL_PLAN_PHASE"
    
    if echo "$INSTALL_PLAN_PHASE" | grep -q "false"; then
        log "  InstallPlan is not approved, approving..."
        oc patch installplan $INSTALL_PLAN -n $OPERATOR_NAMESPACE --type merge -p '{"spec":{"approved":true}}' 2>/dev/null || warning "Failed to approve InstallPlan"
    fi
fi

# Wait for the operator to be installed
log "Waiting for Cluster Observability Operator to be installed..."
log "This may take a few minutes..."

# Wait for CSV to be created and installed
log "Waiting for ClusterServiceVersion to be created..."
MAX_WAIT=60
WAIT_COUNT=0
while ! oc get csv -n $OPERATOR_NAMESPACE 2>/dev/null | grep -q cluster-observability-operator; do
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        log ""
        log "CSV not created after $((MAX_WAIT * 10)) seconds. Diagnostic information:"
        log ""
        
        # Check if subscription exists
        log "Checking if subscription exists..."
        if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
            log "  ✓ Subscription exists"
            log ""
            log "Subscription status summary:"
            SUB_STATE=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
            SUB_CURRENT_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "none")
            SUB_INSTALLED_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "none")
            log "  State: $SUB_STATE"
            log "  Current CSV: $SUB_CURRENT_CSV"
            log "  Installed CSV: $SUB_INSTALLED_CSV"
            log ""
            log "Subscription conditions:"
            oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}' 2>/dev/null || log "  Could not get conditions"
            log ""
            log "Full subscription details:"
            oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o yaml 2>/dev/null | grep -A 30 "status:" || log "  Could not get subscription status"
        else
            log "  ✗ Subscription NOT FOUND in namespace $OPERATOR_NAMESPACE"
            log ""
            log "Checking all subscriptions in namespace:"
            oc get subscription.operators.coreos.com -n $OPERATOR_NAMESPACE 2>&1 || log "  No subscriptions found"
            log ""
            log "Checking if subscription exists in other namespaces:"
            oc get subscription.operators.coreos.com cluster-observability-operator --all-namespaces 2>&1 || log "  Subscription not found anywhere"
        fi
        log ""
        
        # Check OperatorGroup
        log "OperatorGroup status:"
        oc get operatorgroup -n $OPERATOR_NAMESPACE 2>&1 || log "  No OperatorGroup found"
        log ""
        
        # Check InstallPlan
        log "InstallPlan status:"
        oc get installplan -n $OPERATOR_NAMESPACE 2>&1 || log "  No InstallPlan found"
        log ""
        
        # Check operator catalog
        log "Checking operator catalog availability..."
        oc get packagemanifest cluster-observability-operator -n openshift-marketplace 2>&1 || log "  Package manifest not found in catalog"
        log ""
        
        # Check CSV in all namespaces
        log "Checking for CSV in any namespace:"
        oc get csv --all-namespaces 2>/dev/null | grep cluster-observability-operator || log "  No CSV found"
        log ""
        
        error "CSV not created after $((MAX_WAIT * 10)) seconds. Check subscription status: oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE"
    fi
    
    # Show progress every 6 iterations (every minute)
    if [ $((WAIT_COUNT % 6)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        # Check subscription state periodically
        if oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
            CURRENT_STATE=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
            CURRENT_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "none")
            INSTALLED_CSV=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "none")
            
            log "Waiting for CSV to be created... ($WAIT_COUNT/$MAX_WAIT) - Subscription state: $CURRENT_STATE"
            if [ "$CURRENT_CSV" != "none" ] && [ -n "$CURRENT_CSV" ]; then
                log "  Current CSV: $CURRENT_CSV"
            fi
            if [ "$INSTALLED_CSV" != "none" ] && [ -n "$INSTALLED_CSV" ]; then
                log "  Installed CSV: $INSTALLED_CSV"
            fi
            
            # Check for error conditions
            ERROR_CONDITION=$(oc get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.conditions[?(@.status=="True" && @.type=="CatalogSourcesUnhealthy")].message}' 2>/dev/null || echo "")
            if [ -n "$ERROR_CONDITION" ]; then
                warning "  Subscription error: $ERROR_CONDITION"
            fi
            
            # Check for InstallPlan
            INSTALL_PLAN_CHECK=$(oc get installplan -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$INSTALL_PLAN_CHECK" ]; then
                INSTALL_PLAN_PHASE=$(oc get installplan $INSTALL_PLAN_CHECK -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
                log "  InstallPlan: $INSTALL_PLAN_CHECK (phase: $INSTALL_PLAN_PHASE)"
            else
                log "  No InstallPlan found yet"
            fi
        else
            log "Waiting for CSV to be created... ($WAIT_COUNT/$MAX_WAIT) - WARNING: Subscription not found!"
        fi
    else
        log "Waiting for CSV to be created... ($WAIT_COUNT/$MAX_WAIT)"
    fi
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Get the CSV name
CSV_NAME=$(oc get csv -n $OPERATOR_NAMESPACE -o name 2>/dev/null | grep cluster-observability-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
if [ -z "$CSV_NAME" ]; then
    # Fallback: try getting CSV by label
    CSV_NAME=$(oc get csv -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
if [ -z "$CSV_NAME" ]; then
    error "Failed to find CSV name for cluster-observability-operator"
fi
log "Found CSV: $CSV_NAME"

# Wait for CSV to be in Succeeded phase
log "Waiting for ClusterServiceVersion to be installed..."
if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n $OPERATOR_NAMESPACE --timeout=300s; then
    CSV_STATUS=$(oc get csv "$CSV_NAME" -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    error "CSV failed to reach Succeeded phase. Current status: $CSV_STATUS. Check CSV details: oc describe csv $CSV_NAME -n $OPERATOR_NAMESPACE"
fi
log "✓ CSV is in Succeeded phase"

# Wait for the operator deployment to appear (it may take time after CSV succeeds)
log "Waiting for Cluster Observability Operator deployment to be created..."
DEPLOYMENT_NAME="cluster-observability-operator"
MAX_DEPLOYMENT_WAIT=60
DEPLOYMENT_WAIT_COUNT=0
DEPLOYMENT_FOUND=false

while [ $DEPLOYMENT_WAIT_COUNT -lt $MAX_DEPLOYMENT_WAIT ]; do
    if oc get deployment $DEPLOYMENT_NAME -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
        DEPLOYMENT_FOUND=true
        log "✓ Deployment found: $DEPLOYMENT_NAME"
        break
    fi
    
    # Try to find deployment by label if the name doesn't match
    ALTERNATIVE_DEPLOYMENT=$(oc get deployment -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$ALTERNATIVE_DEPLOYMENT" ]; then
        DEPLOYMENT_NAME="$ALTERNATIVE_DEPLOYMENT"
        DEPLOYMENT_FOUND=true
        log "✓ Deployment found with label: $DEPLOYMENT_NAME"
        break
    fi
    
    # Check for any deployment in the namespace (fallback)
    ANY_DEPLOYMENT=$(oc get deployment -n $OPERATOR_NAMESPACE -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$ANY_DEPLOYMENT" ]; then
        log "Found deployment in namespace: $ANY_DEPLOYMENT (will check if it's the operator)"
        DEPLOYMENT_NAME="$ANY_DEPLOYMENT"
        DEPLOYMENT_FOUND=true
        break
    fi
    
    if [ $((DEPLOYMENT_WAIT_COUNT % 6)) -eq 0 ]; then
        log "Waiting for deployment to appear... ($DEPLOYMENT_WAIT_COUNT/$MAX_DEPLOYMENT_WAIT)"
    fi
    sleep 10
    DEPLOYMENT_WAIT_COUNT=$((DEPLOYMENT_WAIT_COUNT + 1))
done

if [ "$DEPLOYMENT_FOUND" = false ]; then
    warning "Deployment not found after $((MAX_DEPLOYMENT_WAIT * 10)) seconds. Checking namespace contents..."
    oc get all -n $OPERATOR_NAMESPACE
    warning "Continuing anyway - operator may be installed but deployment may have different name or structure"
else
    # Wait for the deployment to be ready
    log "Waiting for deployment $DEPLOYMENT_NAME to be Available..."
    if ! oc wait --for=condition=Available "deployment/$DEPLOYMENT_NAME" -n $OPERATOR_NAMESPACE --timeout=300s; then
        warning "Deployment $DEPLOYMENT_NAME did not become Available within timeout. Checking status..."
        oc get deployment $DEPLOYMENT_NAME -n $OPERATOR_NAMESPACE
        oc describe deployment $DEPLOYMENT_NAME -n $OPERATOR_NAMESPACE | head -50
        warning "Continuing anyway - operator CSV is Succeeded, which indicates successful installation"
    else
        log "✓ Cluster Observability Operator deployment is ready"
    fi
fi

# Verify installation
log "Verifying Cluster Observability Operator installation..."

# Check if the operator deployment exists
if oc get deployment $DEPLOYMENT_NAME -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    log "✓ Cluster Observability Operator deployment found: $DEPLOYMENT_NAME"
else
    warning "Deployment $DEPLOYMENT_NAME not found. Checking all deployments in namespace..."
    oc get deployment -n $OPERATOR_NAMESPACE
fi

# Check operator pods
log "Checking operator pods..."
POD_STATUS=$(oc get pods -n $OPERATOR_NAMESPACE -l name=cluster-observability-operator -o jsonpath='{.items[*].status.phase}' || echo "")
if [ -z "$POD_STATUS" ]; then
    # Try alternative label selector
    POD_STATUS=$(oc get pods -n $OPERATOR_NAMESPACE -l app=cluster-observability-operator -o jsonpath='{.items[*].status.phase}' || echo "")
fi
if [ -n "$POD_STATUS" ]; then
    oc get pods -n $OPERATOR_NAMESPACE -l name=cluster-observability-operator 2>/dev/null || oc get pods -n $OPERATOR_NAMESPACE -l app=cluster-observability-operator
else
    warning "No Cluster Observability Operator pods found with standard labels. Checking all pods in namespace..."
    oc get pods -n $OPERATOR_NAMESPACE
fi

# Verify pods are running
if [ -n "$POD_STATUS" ] && echo "$POD_STATUS" | grep -qv "Running"; then
    warning "Some Cluster Observability Operator pods are not Running. Current status: $POD_STATUS"
else
    log "✓ All Cluster Observability Operator pods are Running"
fi

# Check CSV (ClusterServiceVersion)
log "Checking ClusterServiceVersion..."
if ! oc get csv -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator >/dev/null 2>&1; then
    warning "Cluster Observability Operator CSV not found with expected label. Checking all CSVs..."
    oc get csv -n $OPERATOR_NAMESPACE
else
    oc get csv -n $OPERATOR_NAMESPACE -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability-operator
fi

# Display operator status
log ""
log "Cluster Observability Operator installation completed successfully!"
log "========================================================="
log "Namespace: $OPERATOR_NAMESPACE"
log "Operator: cluster-observability-operator"
log "CSV: $CSV_NAME"
log "========================================================="
log ""

# Step 2: Install Cluster Observability Operator resources
log ""
log "========================================================="
log "Step 2: Installing Cluster Observability Operator resources"
log "========================================================="

# Verify monitoring-setup directory exists (always check, even if operator is installed)
log "Verifying monitoring-setup directory and YAML files..."
if [ ! -d "$MONITORING_SETUP_DIR" ]; then
    error "Monitoring setup directory not found: $MONITORING_SETUP_DIR"
fi
log "✓ Monitoring setup directory found: $MONITORING_SETUP_DIR"

# Verify all required YAML files exist
REQUIRED_FILES=(
    "$MONITORING_SETUP_DIR/cluster-observability-operator/monitoring-stack.yaml"
    "$MONITORING_SETUP_DIR/cluster-observability-operator/scrape-config.yaml"
    "$MONITORING_SETUP_DIR/prometheus-operator/additional-scrape-config.yaml"
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus.yaml"
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus-rule.yaml"
    "$MONITORING_SETUP_DIR/rhacs/declarative-configuration-configmap.yaml"
    "$MONITORING_SETUP_DIR/perses/datasource.yaml"
    "$MONITORING_SETUP_DIR/perses/dashboard.yaml"
    "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml"
)

MISSING_FILES=()
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        MISSING_FILES+=("$file")
    fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    error "Required YAML files not found: ${MISSING_FILES[*]}"
fi
log "✓ All required YAML files found"

# Function to apply YAML with namespace substitution
apply_yaml_with_namespace() {
    local yaml_file="$1"
    local description="$2"
    
    if [ ! -f "$yaml_file" ]; then
        error "YAML file not found: $yaml_file"
    fi
    
    log "Installing $description..."
    # Replace namespace in YAML file:
    # - namespace: tssc-acs -> namespace: $NAMESPACE
    # - namespace: "tssc-acs" -> namespace: "$NAMESPACE"
    # - .tssc-acs.svc -> .$NAMESPACE.svc (for service references)
    # - .tssc-acs.svc.cluster.local -> .$NAMESPACE.svc.cluster.local
    sed "s/namespace: tssc-acs/namespace: $NAMESPACE/g; \
         s/namespace: \"tssc-acs\"/namespace: \"$NAMESPACE\"/g; \
         s/\\.tssc-acs\\.svc\\.cluster\\.local/\\.$NAMESPACE\\.svc\\.cluster\\.local/g; \
         s/\\.tssc-acs\\.svc/\\.$NAMESPACE\\.svc/g" "$yaml_file" | \
        oc apply -f - || error "Failed to apply $yaml_file"
    log "✓ $description installed successfully"
}

# Install MonitoringStack
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/cluster-observability-operator/monitoring-stack.yaml" \
    "MonitoringStack (rhacs-monitoring-stack)"

# Wait a moment for MonitoringStack to be processed
sleep 5

# Install ScrapeConfig
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/cluster-observability-operator/scrape-config.yaml" \
    "ScrapeConfig (rhacs-scrape-config)"

log ""
log "Cluster Observability Operator resources installed successfully!"
log ""

# Step 3: Install Prometheus Operator resources
log ""
log "========================================================="
log "Step 3: Installing Prometheus Operator resources"
log "========================================================="

# Install Prometheus additional scrape config secret
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/prometheus-operator/additional-scrape-config.yaml" \
    "Prometheus additional scrape config secret"

# Install Prometheus custom resource
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus.yaml" \
    "Prometheus (rhacs-prometheus-server)"

# Install PrometheusRule
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus-rule.yaml" \
    "PrometheusRule (rhacs-health-alerts)"

log ""
log "Prometheus Operator resources installed successfully!"
log ""

# Step 4: Install RHACS declarative configuration
log ""
log "========================================================="
log "Step 4: Installing RHACS declarative configuration"
log "========================================================="

apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/rhacs/declarative-configuration-configmap.yaml" \
    "RHACS declarative configuration ConfigMap"

log ""
log "RHACS declarative configuration installed successfully!"
log ""

# Step 5: Install Perses resources
log ""
log "========================================================="
log "Step 5: Installing Perses monitoring resources"
log "========================================================="

# Install Perses datasource
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/perses/datasource.yaml" \
    "Perses Datasource (rhacs-datasource)"

# Install Perses dashboard
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/perses/dashboard.yaml" \
    "Perses Dashboard (rhacs-dashboard)"

# Install Perses UI plugin
# Note: UI plugin might be cluster-scoped, check if namespace substitution is needed
log "Installing Perses UI Plugin..."
if grep -q "namespace:" "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml"; then
    apply_yaml_with_namespace \
        "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml" \
        "Perses UI Plugin"
else
    log "Installing Perses UI Plugin (cluster-scoped)..."
    oc apply -f "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml" || error "Failed to apply UI plugin"
    log "✓ Perses UI Plugin installed successfully"
fi

log ""
log "Perses monitoring resources installed successfully!"
log ""
fi  # End of SKIP_INSTALLATION check for operator installation

# Always ensure monitoring resources are installed (even if operator was already installed)
# This ensures YAML files are always applied, which is idempotent
log ""
log "========================================================="
log "Ensuring all monitoring-setup YAML files are installed"
log "========================================================="

# Verify monitoring-setup directory exists
if [ ! -d "$MONITORING_SETUP_DIR" ]; then
    error "Monitoring setup directory not found: $MONITORING_SETUP_DIR"
fi
log "✓ Monitoring setup directory found: $MONITORING_SETUP_DIR"

# Verify all required YAML files exist before attempting installation
REQUIRED_FILES=(
    "$MONITORING_SETUP_DIR/cluster-observability-operator/monitoring-stack.yaml"
    "$MONITORING_SETUP_DIR/cluster-observability-operator/scrape-config.yaml"
    "$MONITORING_SETUP_DIR/prometheus-operator/additional-scrape-config.yaml"
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus.yaml"
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus-rule.yaml"
    "$MONITORING_SETUP_DIR/rhacs/declarative-configuration-configmap.yaml"
    "$MONITORING_SETUP_DIR/perses/datasource.yaml"
    "$MONITORING_SETUP_DIR/perses/dashboard.yaml"
    "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml"
)

log "Verifying all required YAML files exist..."
MISSING_FILES=()
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        MISSING_FILES+=("$file")
    else
        log "  ✓ Found: $(basename "$file")"
    fi
done

if [ ${#MISSING_FILES[@]} -gt 0 ]; then
    error "Required YAML files not found: ${MISSING_FILES[*]}"
fi
log "✓ All required YAML files verified"

# Function to apply YAML with namespace substitution (reuse if already defined, otherwise define it)
if ! type apply_yaml_with_namespace &>/dev/null; then
    apply_yaml_with_namespace() {
        local yaml_file="$1"
        local description="$2"
        
        if [ ! -f "$yaml_file" ]; then
            error "YAML file not found: $yaml_file"
        fi
        
        log "Installing $description..."
        # Replace namespace in YAML file:
        # - namespace: tssc-acs -> namespace: $NAMESPACE
        # - namespace: "tssc-acs" -> namespace: "$NAMESPACE"
        # - .tssc-acs.svc -> .$NAMESPACE.svc (for service references)
        # - .tssc-acs.svc.cluster.local -> .$NAMESPACE.svc.cluster.local
        sed "s/namespace: tssc-acs/namespace: $NAMESPACE/g; \
             s/namespace: \"tssc-acs\"/namespace: \"$NAMESPACE\"/g; \
             s/\\.tssc-acs\\.svc\\.cluster\\.local/\\.$NAMESPACE\\.svc\\.cluster\\.local/g; \
             s/\\.tssc-acs\\.svc/\\.$NAMESPACE\\.svc/g" "$yaml_file" | \
            oc apply -f - || error "Failed to apply $yaml_file"
        log "✓ $description installed successfully"
    }
fi

# Install all monitoring resources (idempotent - safe to run multiple times)
log "Installing Cluster Observability Operator resources..."
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/cluster-observability-operator/monitoring-stack.yaml" \
    "MonitoringStack (rhacs-monitoring-stack)"

sleep 2

apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/cluster-observability-operator/scrape-config.yaml" \
    "ScrapeConfig (rhacs-scrape-config)"

log ""
log "Installing Prometheus Operator resources..."
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/prometheus-operator/additional-scrape-config.yaml" \
    "Prometheus additional scrape config secret"

apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus.yaml" \
    "Prometheus (rhacs-prometheus-server)"

apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/prometheus-operator/prometheus-rule.yaml" \
    "PrometheusRule (rhacs-health-alerts)"

log ""
log "Installing RHACS declarative configuration..."
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/rhacs/declarative-configuration-configmap.yaml" \
    "RHACS declarative configuration ConfigMap"

log ""
log "Installing Perses monitoring resources..."
apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/perses/datasource.yaml" \
    "Perses Datasource (rhacs-datasource)"

apply_yaml_with_namespace \
    "$MONITORING_SETUP_DIR/perses/dashboard.yaml" \
    "Perses Dashboard (rhacs-dashboard)"

# Install Perses UI plugin (may be cluster-scoped)
log "Installing Perses UI Plugin..."
if grep -q "namespace:" "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml"; then
    apply_yaml_with_namespace \
        "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml" \
        "Perses UI Plugin"
else
    log "Installing Perses UI Plugin (cluster-scoped)..."
    oc apply -f "$MONITORING_SETUP_DIR/perses/ui-plugin.yaml" || error "Failed to apply UI plugin"
    log "✓ Perses UI Plugin installed successfully"
fi

log ""
log "✓ All monitoring-setup YAML files have been installed/updated"

# Final summary
log ""
log "========================================================="
if [ "$SKIP_INSTALLATION" = true ]; then
    log "Perses Monitoring Setup - Already Installed"
    log "========================================================="
    log "All components were already installed:"
else
    log "Perses Monitoring Setup Completed Successfully!"
    log "========================================================="
    log "All monitoring resources have been installed:"
fi
log "  ✓ TLS certificate for RHACS Prometheus"
log "  ✓ Cluster Observability Operator"
log "  ✓ MonitoringStack and ScrapeConfig"
log "  ✓ Prometheus Operator resources"
log "  ✓ RHACS declarative configuration"
log "  ✓ Perses datasource, dashboard, and UI plugin"
log "========================================================="
log ""

