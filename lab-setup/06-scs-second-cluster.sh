#!/bin/bash
# ACS Setup Script
# Downloads and sets up roxctl CLI and switches to local-cluster context
#
# Usage:
#   ./acs-setup.sh [--init-bundle FILE] [-i FILE]
#   
# Options:
#   --init-bundle, -i    Path to an existing init-bundle.yaml file containing secrets
#                        If not provided, the script will generate one automatically

# Exit immediately on error, show error message
set -euo pipefail

# Parse command line arguments
PROVIDED_INIT_BUNDLE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --init-bundle|-i)
            PROVIDED_INIT_BUNDLE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--init-bundle FILE] [-i FILE]"
            echo ""
            echo "Options:"
            echo "  --init-bundle, -i    Path to an existing init-bundle.yaml file containing secrets"
            echo "                      If not provided, the script will generate one automatically"
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[ACS-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[ACS-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[ACS-SETUP] ERROR:${NC} $1" >&2
    echo -e "${RED}[ACS-SETUP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        ROXCTL_ARCH="linux"
        ;;
    aarch64|arm64)
        ROXCTL_ARCH="linux_arm64"
        ;;
    *)
        error "Unsupported architecture: $ARCH"
        ;;
esac

# Check if roxctl is available and install if not
log "Checking for roxctl CLI..."
ROXCTL_VERSION="4.9.0"
ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${ROXCTL_VERSION}/bin/${ROXCTL_ARCH}/roxctl"
ROXCTL_TMP="/tmp/roxctl"

if command -v roxctl >/dev/null 2>&1; then
    # Try to get version - handle both plain text and JSON output
    INSTALLED_VERSION=$(roxctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    
    # If that didn't work, try JSON format
    if [ -z "$INSTALLED_VERSION" ]; then
        INSTALLED_VERSION=$(roxctl version --output json 2>/dev/null | grep -oE '"version":\s*"[^"]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    fi
    
    if [ -n "$INSTALLED_VERSION" ] && [[ "$INSTALLED_VERSION" == 4.9.* ]]; then
        log "roxctl version $INSTALLED_VERSION is already installed"
    else
        log "roxctl exists but is not version 4.9 (found: ${INSTALLED_VERSION:-unknown}), downloading version $ROXCTL_VERSION..."
        curl -k -L -o "$ROXCTL_TMP" "$ROXCTL_URL" || error "Failed to download roxctl"
        chmod +x "$ROXCTL_TMP"
        sudo mv "$ROXCTL_TMP" /usr/local/bin/roxctl || error "Failed to move roxctl to /usr/local/bin"
        log "roxctl version $ROXCTL_VERSION installed successfully"
    fi
else
    log "roxctl not found, installing version $ROXCTL_VERSION..."
    curl -k -L -o "$ROXCTL_TMP" "$ROXCTL_URL" || error "Failed to download roxctl"
    chmod +x "$ROXCTL_TMP"
    sudo mv "$ROXCTL_TMP" /usr/local/bin/roxctl || error "Failed to move roxctl to /usr/local/bin"
    log "roxctl version $ROXCTL_VERSION installed successfully"
fi

# Verify installation
if ! command -v roxctl >/dev/null 2>&1; then
    error "roxctl installation verification failed"
fi

log "roxctl CLI setup complete"

# Switch to local-cluster context
log "Switching to local-cluster context..."

# Check if oc/kubectl is available
if ! command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
    error "oc or kubectl not found. Cannot switch context."
fi

# Use oc if available, otherwise kubectl
KUBECTL_CMD="oc"
if ! command -v oc >/dev/null 2>&1; then
    KUBECTL_CMD="kubectl"
fi

# Switch to local-cluster context
if $KUBECTL_CMD config use-context local-cluster >/dev/null 2>&1; then
    log "✓ Switched to local-cluster context"
else
    error "Failed to switch to local-cluster context. Please ensure the context exists."
fi

# Deploy Secured Cluster Services to aws-us cluster
log "Deploying Secured Cluster Services to aws-us cluster..."

# Ensure we're on local-cluster to get Central information
if ! $KUBECTL_CMD config use-context local-cluster >/dev/null 2>&1; then
    error "Failed to switch to local-cluster context. Cannot retrieve Central information."
fi

RHACS_OPERATOR_NAMESPACE="rhacs-operator"
CLUSTER_NAME="aws-us"
SECURED_CLUSTER_NAME="aws-us"

# Get Central endpoint from route (automatically retrieve from cluster, ignore .bashrc completely)
log "Retrieving Central endpoint from cluster (ignoring .bashrc)..."
# Get all routes in the namespace and find the correct Central route
ALL_ROUTES=$($KUBECTL_CMD get routes -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\t"}{.spec.to.name}{"\n"}{end}' 2>/dev/null || echo "")

# Look for route that matches pattern: central.apps.* (not central-stackrox.*)
PREFERRED_ROUTE=""
FALLBACK_ROUTE=""

while IFS=$'\t' read -r route_name route_host route_service; do
    if [ -z "$route_host" ]; then
        continue
    fi
    
    # Prefer routes that match "central.apps.*" pattern (not "central-stackrox.*")
    if [[ "$route_host" == central.apps.* ]] && [[ "$route_host" != central-stackrox.* ]]; then
        PREFERRED_ROUTE="$route_host"
        log "Found preferred Central route: $route_name -> $route_host"
        break
    # Also check if route points to central service
    elif [[ "$route_service" == *"central"* ]] && [[ "$route_host" != central-stackrox.* ]]; then
        if [ -z "$FALLBACK_ROUTE" ]; then
            FALLBACK_ROUTE="$route_host"
            log "Found Central route (by service): $route_name -> $route_host"
        fi
    fi
done <<< "$ALL_ROUTES"

# Use preferred route if found, otherwise fallback
if [ -n "$PREFERRED_ROUTE" ]; then
    CENTRAL_ROUTE="$PREFERRED_ROUTE"
elif [ -n "$FALLBACK_ROUTE" ]; then
    CENTRAL_ROUTE="$FALLBACK_ROUTE"
else
    # Last resort: try route named "central"
    CENTRAL_ROUTE=$($KUBECTL_CMD get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
fi

# If still not found, try openshift-operators namespace
if [ -z "$CENTRAL_ROUTE" ]; then
    log "Searching in openshift-operators namespace..."
    CENTRAL_ROUTE=$($KUBECTL_CMD get route central -n openshift-operators -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
fi

if [ -z "$CENTRAL_ROUTE" ]; then
    error "Central route not found. Please ensure RHACS Central is installed."
fi

# Find the route name to check TLS
ROUTE_NAME=$(oc get route -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath="{range .items[?(@.spec.host=='$CENTRAL_ROUTE')]}{.metadata.name}{end}" 2>/dev/null || echo "")
if [ -z "$ROUTE_NAME" ]; then
    ROUTE_NAME="central"
fi

# Check if route uses TLS
CENTRAL_TLS=$(oc get route "$ROUTE_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.tls}' 2>/dev/null || echo "")

if [ -n "$CENTRAL_TLS" ] && [ "$CENTRAL_TLS" != "null" ]; then
    CENTRAL_URL="https://${CENTRAL_ROUTE}"
    ROX_ENDPOINT="${CENTRAL_ROUTE}:443"
else
    CENTRAL_URL="http://${CENTRAL_ROUTE}"
    ROX_ENDPOINT="${CENTRAL_ROUTE}"
fi
ROX_CENTRAL_ADDRESS="$CENTRAL_URL"
log "✓ Central endpoint from route: $ROX_CENTRAL_ADDRESS (route: $ROUTE_NAME)"

# Normalize endpoint for API calls (strip protocol, path, ensure port)
normalize_rox_endpoint() {
    local input="$1"
    # Strip protocol
    input="${input#https://}"
    input="${input#http://}"
    # Strip any path (everything after first /)
    input="${input%%/*}"
    # Strip trailing slash
    input="${input%/}"
    # Ensure port is present
    if [[ "$input" != *:* ]]; then
        input="${input}:443"
    fi
    echo "$input"
}

ROX_ENDPOINT_NORMALIZED="$(normalize_rox_endpoint "$ROX_ENDPOINT")"

# Get admin password from secret (automatically retrieve from cluster)
log "Retrieving admin password from cluster secret..."
ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
if [ -z "$ADMIN_PASSWORD_B64" ]; then
    error "Admin password secret 'central-htpasswd' not found in namespace '$RHACS_OPERATOR_NAMESPACE'. Please ensure RHACS Central is installed."
fi

ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
if [ -z "$ADMIN_PASSWORD" ]; then
    error "Failed to decode admin password from secret."
fi

ACS_PORTAL_USERNAME="admin"
ACS_PORTAL_PASSWORD="$ADMIN_PASSWORD"
log "✓ Admin password retrieved from secret (username: admin)"

# Generate API token (ignore .bashrc, always query cluster for fresh values)
log ""
log "Generating RHACS API token..."
ROX_API_TOKEN=""

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
    log "jq is required for token extraction. Installing jq..."
    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y jq >/dev/null 2>&1 || warning "Failed to install jq using dnf"
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y jq >/dev/null 2>&1 || warning "Failed to install jq using apt-get"
    else
        warning "Cannot install jq automatically. Please install jq manually."
    fi
fi

if command -v jq >/dev/null 2>&1; then
    # Wait for Central API to be ready
    log "Waiting for Central API to be ready..."
    MAX_RETRIES=30
    RETRY_COUNT=0
    API_READY=false
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" "${ROX_CENTRAL_ADDRESS}/v1/metadata" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ]; then
            API_READY=true
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep 2
    done
    
    if [ "$API_READY" = true ]; then
        # Generate token using curl
        set +e
        ROX_API_TOKEN=$(curl -sk \
            -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" \
            -H "Content-Type: application/json" \
            --data-raw '{"name": "cli-admin-token", "roles": ["Admin"]}' \
            "${ROX_CENTRAL_ADDRESS}/v1/apitokens/generate" \
            | jq -r '.token' 2>/dev/null)
        TOKEN_EXIT_CODE=$?
        set -e

        if [ $TOKEN_EXIT_CODE -eq 0 ] && [ -n "$ROX_API_TOKEN" ] && [ "$ROX_API_TOKEN" != "null" ] && [ ${#ROX_API_TOKEN} -ge 20 ]; then
            log "✓ API token generated successfully"
        else
            warning "Failed to generate API token. Will use password authentication instead."
            ROX_API_TOKEN=""
        fi
    else
        warning "Central API not ready after ${MAX_RETRIES} retries. Will use password authentication instead."
        ROX_API_TOKEN=""
    fi
else
    warning "jq is not available. Cannot extract token. Will use password authentication instead."
    ROX_API_TOKEN=""
fi

# Handle init bundle - either use provided file or generate one
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_BUNDLES_DIR="${SCRIPT_DIR}/init-bundles"
mkdir -p "$INIT_BUNDLES_DIR"
# Generate random number to avoid filename conflicts
RANDOM_SUFFIX=$((RANDOM % 10000))
INIT_BUNDLE_FILE="${INIT_BUNDLES_DIR}/${CLUSTER_NAME}-init-bundle-${RANDOM_SUFFIX}.yaml"

# Check if user provided an init bundle file
if [ -n "$PROVIDED_INIT_BUNDLE" ]; then
    log "Using provided init bundle file: $PROVIDED_INIT_BUNDLE"
    
    # Validate the provided file exists
    if [ ! -f "$PROVIDED_INIT_BUNDLE" ]; then
        error "Init bundle file not found: $PROVIDED_INIT_BUNDLE"
    fi
    
    # Validate the file contains valid secrets
    if ! grep -q "kind: Secret" "$PROVIDED_INIT_BUNDLE" 2>/dev/null; then
        error "Provided init bundle file does not appear to contain valid Secret resources: $PROVIDED_INIT_BUNDLE"
    fi
    
    # Check for required secrets
    REQUIRED_SECRETS=("sensor-tls" "admission-control-tls" "collector-tls")
    MISSING_SECRETS=()
    for secret in "${REQUIRED_SECRETS[@]}"; do
        if ! grep -q "name: $secret" "$PROVIDED_INIT_BUNDLE" 2>/dev/null; then
            MISSING_SECRETS+=("$secret")
        fi
    done
    
    if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
        warning "Init bundle file may be missing some required secrets: ${MISSING_SECRETS[*]}"
        warning "This may cause deployment issues. Please verify the init bundle is complete."
    fi
    
    # CRITICAL: Check if bundle contains wildcard ID - this causes sensor panic (Red Hat Solution 6972449)
    if grep -q "00000000-0000-0000-0000-000000000000" "$PROVIDED_INIT_BUNDLE" 2>/dev/null; then
        error "Provided init bundle contains wildcard ID '00000000-0000-0000-0000-000000000000' - this will cause sensor panic!"
        error "Error: Invalid dynamic cluster ID value - no concrete cluster ID was specified"
        error "Please regenerate the init bundle in Central and ensure it has a concrete cluster ID."
        error "Init bundle file: $PROVIDED_INIT_BUNDLE"
    fi
    
    # Use the provided file
    INIT_BUNDLE_FILE="$PROVIDED_INIT_BUNDLE"
    log "✓ Using provided init bundle file: $INIT_BUNDLE_FILE"
    SKIP_BUNDLE_GENERATION=true
else
    log "No init bundle file provided, will generate one for cluster: $CLUSTER_NAME (while on local-cluster)..."
    SKIP_BUNDLE_GENERATION=false
fi

# Generate init bundle if not provided
if [ "$SKIP_BUNDLE_GENERATION" = "false" ]; then
    # Ensure jq is available for JSON parsing
    if ! command -v jq >/dev/null 2>&1; then
        warning "jq is required for init bundle generation. Installing jq..."
        if command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y jq >/dev/null 2>&1 || error "Failed to install jq using dnf"
        elif command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y jq >/dev/null 2>&1 || error "Failed to install jq using apt-get"
        else
            error "Cannot install jq automatically. Please install jq manually."
        fi
    fi

    # Use API token if we generated it, otherwise use admin password
    # Do not load from .bashrc - use only values retrieved from cluster

# Construct Central API URL using the retrieved Central address
CENTRAL_API_URL="${ROX_CENTRAL_ADDRESS}"
CENTRAL_API_URL="${CENTRAL_API_URL%/}"

# Determine authentication method
if [ -n "${ROX_API_TOKEN:-}" ] && [ "${ROX_API_TOKEN}" != "null" ] && [ "${ROX_API_TOKEN}" != "" ]; then
    AUTH_HEADER="Authorization: Bearer ${ROX_API_TOKEN}"
    AUTH_METHOD="token"
    log "Using API token for authentication"
else
    AUTH_HEADER=""
    AUTH_METHOD="password"
    log "Using admin password for authentication"
fi

# Test API connectivity
log "Testing Central API connectivity..."
if [ "$AUTH_METHOD" = "token" ]; then
    TEST_RESPONSE=$(curl -sk -w "\n%{http_code}" -H "$AUTH_HEADER" "${CENTRAL_API_URL}/v1/metadata" 2>&1)
else
    TEST_RESPONSE=$(curl -sk -w "\n%{http_code}" -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" "${CENTRAL_API_URL}/v1/metadata" 2>&1)
fi
HTTP_CODE=$(echo "$TEST_RESPONSE" | tail -1)
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "000" ]; then
    warning "Central API test returned HTTP $HTTP_CODE - authentication may be failing"
    if [ "$AUTH_METHOD" = "password" ]; then
        warning "Consider generating ROX_API_TOKEN for better authentication"
    fi
else
    log "✓ Central API is reachable"
fi

# Check if init bundle already exists in Central and delete it to avoid wildcard cert issues
# This prevents the "00000000..." wildcard ID issue that causes sensor panic
log "Checking for existing init bundle in Central..."
if [ "$AUTH_METHOD" = "token" ]; then
    EXISTING_BUNDLES=$(curl -sk -H "$AUTH_HEADER" "${CENTRAL_API_URL}/v1/cluster-init/init-bundles" 2>/dev/null || echo "[]")
else
    EXISTING_BUNDLES=$(curl -sk -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" "${CENTRAL_API_URL}/v1/cluster-init/init-bundles" 2>/dev/null || echo "[]")
fi

# Check if bundle with this name exists
BUNDLE_ID=$(echo "$EXISTING_BUNDLES" | jq -r ".[] | select(.name == \"${CLUSTER_NAME}\") | .id" 2>/dev/null | head -1 || echo "")

if [ -n "$BUNDLE_ID" ] && [ "$BUNDLE_ID" != "null" ] && [ "$BUNDLE_ID" != "" ]; then
    log "Found existing init bundle '$CLUSTER_NAME' (ID: $BUNDLE_ID) in Central - deleting to prevent wildcard cert issues..."
    if [ "$AUTH_METHOD" = "token" ]; then
        REVOKE_RESPONSE=$(curl -sk -X DELETE -H "$AUTH_HEADER" "${CENTRAL_API_URL}/v1/cluster-init/init-bundles/${BUNDLE_ID}" 2>&1)
    else
        REVOKE_RESPONSE=$(curl -sk -X DELETE -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" "${CENTRAL_API_URL}/v1/cluster-init/init-bundles/${BUNDLE_ID}" 2>&1)
    fi
    
    if echo "$REVOKE_RESPONSE" | grep -qE "200|204|deleted|revoked" || [ -z "$REVOKE_RESPONSE" ]; then
        log "✓ Existing init bundle revoked/deleted"
        sleep 2
    else
        warning "Failed to revoke existing init bundle: ${REVOKE_RESPONSE:0:200}"
        warning "Will attempt to generate new one anyway"
    fi
else
    log "No existing init bundle found in Central, proceeding with generation"
fi

# Always generate a fresh init bundle to avoid wildcard cert issues
log "Generating fresh init bundle to ensure proper certificate assignment..."
BUNDLE_NAME="$CLUSTER_NAME"

# Create init bundle metadata
# Use the correct API endpoint: /v1/cluster-init/init-bundles (with hyphen)
log "Creating init bundle via API..."
log "Central API URL: ${CENTRAL_API_URL}"
log "Using endpoint: /v1/cluster-init/init-bundles"

# Wait for Central API to be ready before creating init bundle
log "Waiting for Central API to be ready..."
MAX_RETRIES=60
RETRY_COUNT=0
API_READY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if [ "$AUTH_METHOD" = "token" ]; then
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -H "$AUTH_HEADER" "${CENTRAL_API_URL}/v1/metadata" 2>/dev/null || echo "000")
    else
        HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" "${CENTRAL_API_URL}/v1/metadata" 2>/dev/null || echo "000")
    fi
    
    if [ "$HTTP_CODE" = "200" ]; then
        API_READY=true
        log "✓ Central API is ready"
        break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $((RETRY_COUNT % 10)) -eq 0 ]; then
        log "  Still waiting for Central API... (${RETRY_COUNT}s/${MAX_RETRIES}s) - HTTP $HTTP_CODE"
    fi
    sleep 2
done

if [ "$API_READY" = false ]; then
    error "Central API not ready after ${MAX_RETRIES} retries. HTTP code: $HTTP_CODE"
fi

# Create init bundle using the correct endpoint
if [ "$AUTH_METHOD" = "token" ]; then
    CREATE_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${BUNDLE_NAME}\"}" \
        "${CENTRAL_API_URL}/v1/cluster-init/init-bundles" 2>&1)
else
    CREATE_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
        -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"${BUNDLE_NAME}\"}" \
        "${CENTRAL_API_URL}/v1/cluster-init/init-bundles" 2>&1)
fi

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -1)
CREATE_BODY=$(echo "$CREATE_RESPONSE" | sed '$d')

log "API call returned HTTP $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
    log "Response body: ${CREATE_BODY:0:200}"
fi

# Check HTTP status code
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    log "✓ Init bundle creation request successful (HTTP $HTTP_CODE)"
elif [ "$HTTP_CODE" = "409" ] || echo "$CREATE_BODY" | grep -qi "already exists\|AlreadyExists"; then
    log "Init bundle already exists, trying with timestamped name..."
    BUNDLE_NAME="${CLUSTER_NAME}-$(date +%s)"
    RANDOM_SUFFIX=$((RANDOM % 10000))
    INIT_BUNDLE_FILE="${INIT_BUNDLES_DIR}/${BUNDLE_NAME}-init-bundle-${RANDOM_SUFFIX}.yaml"
    
    if [ "$AUTH_METHOD" = "token" ]; then
        CREATE_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"${BUNDLE_NAME}\"}" \
            "${CENTRAL_API_URL}/v1/cluster-init/init-bundles" 2>&1)
    else
        CREATE_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
            -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"${BUNDLE_NAME}\"}" \
            "${CENTRAL_API_URL}/v1/cluster-init/init-bundles" 2>&1)
    fi
    HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -1)
    CREATE_BODY=$(echo "$CREATE_RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
        error "Failed to create timestamped init bundle. HTTP $HTTP_CODE. Response: ${CREATE_BODY:0:500}"
    fi
elif [ "$HTTP_CODE" = "404" ]; then
    # Try alternative API endpoints - different RHACS versions use different paths
    log "API endpoint returned 404, trying alternative endpoints..."
    
    # Try /v1/init-bundles (without clusterinit)
    # Try alternative endpoints if the correct one doesn't work
    ALTERNATIVE_ENDPOINTS=(
        "/v1/cluster-init/init-bundles"  # Correct endpoint (with hyphen)
        "/v1/clusterinit/init-bundles"   # Legacy endpoint (without hyphen)
        "/api/v1/cluster-init/init-bundles"
    )
    
    # Try different request body formats
    REQUEST_BODIES=(
        "{\"name\": \"${BUNDLE_NAME}\"}"
        "{\"initBundle\": {\"name\": \"${BUNDLE_NAME}\"}}"
        "{\"meta\": {\"name\": \"${BUNDLE_NAME}\"}}"
        "{\"name\": \"${BUNDLE_NAME}\", \"type\": \"kubernetes\"}"
    )
    
    BUNDLE_CREATED=false
    for ALT_ENDPOINT in "${ALTERNATIVE_ENDPOINTS[@]}"; do
        for REQUEST_BODY in "${REQUEST_BODIES[@]}"; do
            log "  Trying: ${CENTRAL_API_URL}${ALT_ENDPOINT}"
        if [ "$AUTH_METHOD" = "token" ]; then
            TEST_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                -d "$REQUEST_BODY" \
                "${CENTRAL_API_URL}${ALT_ENDPOINT}" 2>&1)
        else
            TEST_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
                -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" \
                -H "Content-Type: application/json" \
                -d "$REQUEST_BODY" \
                "${CENTRAL_API_URL}${ALT_ENDPOINT}" 2>&1)
        fi
        TEST_HTTP_CODE=$(echo "$TEST_RESPONSE" | tail -1)
        TEST_BODY=$(echo "$TEST_RESPONSE" | sed '$d')
        
            if [ "$TEST_HTTP_CODE" = "200" ] || [ "$TEST_HTTP_CODE" = "201" ]; then
                log "✓ Found working endpoint: ${ALT_ENDPOINT}"
                CREATE_RESPONSE="$TEST_RESPONSE"
                HTTP_CODE="$TEST_HTTP_CODE"
                CREATE_BODY="$TEST_BODY"
                BUNDLE_CREATED=true
                break 2
            elif [ "$TEST_HTTP_CODE" != "404" ]; then
                log "  Endpoint ${ALT_ENDPOINT} returned HTTP $TEST_HTTP_CODE: ${TEST_BODY:0:100}"
            fi
        done
    done
    
    if [ "$BUNDLE_CREATED" = "false" ]; then
        error "Failed to create init bundle via API. All endpoints returned 404 or error."
        error "This may indicate:"
        error "  1. Incorrect Central API URL: ${CENTRAL_API_URL}"
        error "  2. Authentication failure (check credentials)"
        error "  3. API endpoint structure differs in this RHACS version"
        error "Last response (HTTP $HTTP_CODE): ${CREATE_BODY:0:500}"
        error "Expected endpoint: ${CENTRAL_API_URL}/v1/cluster-init/init-bundles"
        error "Please verify the Central API endpoint and authentication."
    fi
else
    error "Failed to create init bundle. HTTP $HTTP_CODE. Response: ${CREATE_BODY:0:500}"
fi

# Extract bundle ID from response body - try multiple possible JSON structures
NEW_BUNDLE_ID=$(echo "$CREATE_BODY" | jq -r '.id // .meta.id // .data.id // .bundle.id // .initBundle.id // empty' 2>/dev/null || echo "")

# Also check if response is a simple string (some APIs return just the ID)
if [ -z "$NEW_BUNDLE_ID" ] || [ "$NEW_BUNDLE_ID" = "null" ] || [ "$NEW_BUNDLE_ID" = "" ]; then
    # Check if response is a plain UUID string
    if echo "$CREATE_BODY" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        NEW_BUNDLE_ID=$(echo "$CREATE_BODY" | grep -oE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' | head -1)
        log "Found bundle ID as plain UUID: $NEW_BUNDLE_ID"
    fi
fi

if [ -z "$NEW_BUNDLE_ID" ] || [ "$NEW_BUNDLE_ID" = "null" ] || [ "$NEW_BUNDLE_ID" = "" ]; then
    # Try to get bundle ID by name if creation response didn't include it
    log "Bundle ID not in response, querying bundle list..."
    if [ "$AUTH_METHOD" = "token" ]; then
        BUNDLE_LIST=$(curl -sk -H "$AUTH_HEADER" "${CENTRAL_API_URL}/v1/clusterinit/init-bundles" 2>/dev/null || echo "[]")
    else
        BUNDLE_LIST=$(curl -sk -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" "${CENTRAL_API_URL}/v1/clusterinit/init-bundles" 2>/dev/null || echo "[]")
    fi
    
    if [ "$BUNDLE_LIST" != "[]" ] && [ -n "$BUNDLE_LIST" ]; then
        NEW_BUNDLE_ID=$(echo "$BUNDLE_LIST" | jq -r ".[] | select(.name == \"${BUNDLE_NAME}\") | .id" 2>/dev/null | head -1 || echo "")
    fi
fi

if [ -z "$NEW_BUNDLE_ID" ] || [ "$NEW_BUNDLE_ID" = "null" ] || [ "$NEW_BUNDLE_ID" = "" ]; then
    # Try to discover the correct API endpoint by testing different variations
    log "Bundle ID not found in response, attempting to discover correct API endpoint..."
    log "HTTP Code: $HTTP_CODE, Response: ${CREATE_BODY:0:200}"
    
    # Try different API endpoint variations
    API_ENDPOINTS=(
        "/v1/clusterinit/init-bundles"
        "/api/v1/clusterinit/init-bundles"
        "/v1/init-bundles"
        "/api/v1/init-bundles"
    )
    
    BUNDLE_CREATED=false
    for API_ENDPOINT in "${API_ENDPOINTS[@]}"; do
        log "  Testing endpoint: ${CENTRAL_API_URL}${API_ENDPOINT}"
        if [ "$AUTH_METHOD" = "token" ]; then
            TEST_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
                -H "$AUTH_HEADER" \
                -H "Content-Type: application/json" \
                -d "$REQUEST_BODY" \
                "${CENTRAL_API_URL}${API_ENDPOINT}" 2>&1)
        else
            TEST_RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
                -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" \
                -H "Content-Type: application/json" \
                -d "$REQUEST_BODY" \
                "${CENTRAL_API_URL}${API_ENDPOINT}" 2>&1)
        fi
        TEST_HTTP_CODE=$(echo "$TEST_RESPONSE" | tail -1)
        TEST_BODY=$(echo "$TEST_RESPONSE" | sed '$d')
        
        if [ "$TEST_HTTP_CODE" = "200" ] || [ "$TEST_HTTP_CODE" = "201" ]; then
            log "✓ Found working endpoint: ${API_ENDPOINT}"
            CREATE_RESPONSE="$TEST_RESPONSE"
            HTTP_CODE="$TEST_HTTP_CODE"
            CREATE_BODY="$TEST_BODY"
            BUNDLE_CREATED=true
            break
        elif [ "$TEST_HTTP_CODE" != "404" ]; then
            log "  Endpoint ${API_ENDPOINT} returned HTTP $TEST_HTTP_CODE: ${TEST_BODY:0:100}"
        fi
    done
    
    if [ "$BUNDLE_CREATED" = "false" ]; then
        # Try to get bundle ID from the list endpoint if creation didn't return it
        log "Attempting to retrieve bundle ID from bundle list..."
        if [ "$AUTH_METHOD" = "token" ]; then
            BUNDLE_LIST=$(curl -sk -H "$AUTH_HEADER" "${CENTRAL_API_URL}/v1/cluster-init/init-bundles" 2>/dev/null || echo "[]")
        else
            BUNDLE_LIST=$(curl -sk -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" "${CENTRAL_API_URL}/v1/cluster-init/init-bundles" 2>/dev/null || echo "[]")
        fi
        
        if [ "$BUNDLE_LIST" != "[]" ] && [ -n "$BUNDLE_LIST" ]; then
            NEW_BUNDLE_ID=$(echo "$BUNDLE_LIST" | jq -r ".[] | select(.name == \"${BUNDLE_NAME}\") | .id" 2>/dev/null | head -1 || echo "")
            if [ -n "$NEW_BUNDLE_ID" ] && [ "$NEW_BUNDLE_ID" != "null" ] && [ "$NEW_BUNDLE_ID" != "" ]; then
                log "✓ Found bundle ID from list: $NEW_BUNDLE_ID"
                BUNDLE_CREATED=true
            fi
        fi
    fi
    
    if [ "$BUNDLE_CREATED" = "false" ] && ([ -z "$NEW_BUNDLE_ID" ] || [ "$NEW_BUNDLE_ID" = "null" ] || [ "$NEW_BUNDLE_ID" = "" ]); then
        error "Failed to create or find init bundle via API."
        error "HTTP Code: $HTTP_CODE"
        error "Response: ${CREATE_BODY:0:500}"
        error "Central API URL: ${CENTRAL_API_URL}"
        error "Tried endpoints: /v1/clusterinit/init-bundles, /api/v1/clusterinit/init-bundles, /v1/init-bundles, /api/v1/init-bundles"
        error "Please verify:"
        error "  1. Central API URL is correct: ${CENTRAL_API_URL}"
        error "  2. Authentication is working (test with: curl -sk -u user:pass ${CENTRAL_API_URL}/v1/metadata)"
        error "  3. API endpoint structure matches your RHACS version"
    fi
fi

log "Init bundle created with ID: $NEW_BUNDLE_ID"

# Extract the base64-encoded bundle from the JSON response
# The API returns kubectlBundle or helmValuesBundle fields that are base64-encoded
log "Extracting init bundle secrets from API response..."

# The CREATE_BODY contains the JSON response with base64-encoded bundle data
# Try to extract kubectlBundle first (Kubernetes secrets format), then helmValuesBundle
KUBECTL_BUNDLE=$(echo "$CREATE_BODY" | jq -r '.kubectlBundle // empty' 2>/dev/null || echo "")
HELM_BUNDLE=$(echo "$CREATE_BODY" | jq -r '.helmValuesBundle // empty' 2>/dev/null || echo "")

BUNDLE_SECRETS=""

if [ -n "$KUBECTL_BUNDLE" ] && [ "$KUBECTL_BUNDLE" != "null" ] && [ "$KUBECTL_BUNDLE" != "" ]; then
    log "Found kubectlBundle in response, decoding base64..."
    # Decode base64 to get the YAML secrets
    BUNDLE_SECRETS=$(echo "$KUBECTL_BUNDLE" | base64 -d 2>/dev/null || echo "")
    if [ -n "$BUNDLE_SECRETS" ] && echo "$BUNDLE_SECRETS" | grep -q "kind: Secret"; then
        log "✓ Successfully decoded kubectlBundle"
    else
        warning "kubectlBundle decoded but doesn't contain expected Secret resources"
        BUNDLE_SECRETS=""
    fi
fi

# If kubectlBundle didn't work, try helmValuesBundle
if [ -z "$BUNDLE_SECRETS" ] || ! echo "$BUNDLE_SECRETS" | grep -q "kind: Secret"; then
    if [ -n "$HELM_BUNDLE" ] && [ "$HELM_BUNDLE" != "null" ] && [ "$HELM_BUNDLE" != "" ]; then
        log "Found helmValuesBundle in response, decoding base64..."
        BUNDLE_SECRETS=$(echo "$HELM_BUNDLE" | base64 -d 2>/dev/null || echo "")
        if [ -n "$BUNDLE_SECRETS" ]; then
            log "✓ Successfully decoded helmValuesBundle"
            # Note: helmValuesBundle might be in Helm values format, not Kubernetes secrets
            # The operator can handle both formats
        fi
    fi
fi

# If still no secrets, try alternative extraction methods
if [ -z "$BUNDLE_SECRETS" ] || ! echo "$BUNDLE_SECRETS" | grep -q "kind: Secret"; then
    log "Trying alternative field names in JSON response..."
    # Try other possible field names
    ALT_BUNDLE=$(echo "$CREATE_BODY" | jq -r '.bundle // .data.kubectlBundle // .data.helmValuesBundle // .meta.kubectlBundle // empty' 2>/dev/null || echo "")
    if [ -n "$ALT_BUNDLE" ] && [ "$ALT_BUNDLE" != "null" ] && [ "$ALT_BUNDLE" != "" ]; then
        # Check if it's base64 encoded or plain text
        if echo "$ALT_BUNDLE" | grep -qE "^[A-Za-z0-9+/]+=*$" && [ ${#ALT_BUNDLE} -gt 100 ]; then
            # Looks like base64
            BUNDLE_SECRETS=$(echo "$ALT_BUNDLE" | base64 -d 2>/dev/null || echo "")
            log "✓ Decoded bundle from alternative field"
        else
            # Might be plain YAML already
            BUNDLE_SECRETS="$ALT_BUNDLE"
        fi
    fi
fi

if [ -z "$BUNDLE_SECRETS" ]; then
    error "Failed to extract init bundle secrets from API response."
    error "Response structure:"
    echo "$CREATE_BODY" | jq '.' 2>/dev/null | head -20 || echo "$CREATE_BODY" | head -20
    error "Expected fields: kubectlBundle or helmValuesBundle (base64-encoded)"
    error "Please check the API response format."
fi

# Save the bundle secrets to file
echo "$BUNDLE_SECRETS" > "$INIT_BUNDLE_FILE"
log "✓ Init bundle secrets decoded and saved to: $INIT_BUNDLE_FILE"

# Verify the init bundle file contains valid secrets (not wildcard/empty)
log "Validating init bundle contains valid certificate data..."
if grep -q "kind: Secret" "$INIT_BUNDLE_FILE" && grep -q "data:" "$INIT_BUNDLE_FILE"; then
    # CRITICAL: Check if bundle contains wildcard ID - this causes sensor panic (Red Hat Solution 6972449)
    if grep -q "00000000-0000-0000-0000-000000000000" "$INIT_BUNDLE_FILE"; then
        error "Init bundle contains wildcard ID '00000000-0000-0000-0000-000000000000' - this will cause sensor panic!"
        error "Error: Invalid dynamic cluster ID value - no concrete cluster ID was specified"
        error "Please delete the existing init bundle in Central and regenerate it."
        error "The script will attempt to delete and recreate the init bundle..."
        # Try to delete the bundle and regenerate
        if [ -n "$NEW_BUNDLE_ID" ] && [ "$NEW_BUNDLE_ID" != "null" ] && [ "$NEW_BUNDLE_ID" != "" ]; then
            log "Attempting to delete init bundle with ID: $NEW_BUNDLE_ID"
            if [ "$AUTH_METHOD" = "token" ]; then
                curl -sk -X DELETE -H "$AUTH_HEADER" "${CENTRAL_API_URL}/v1/cluster-init/init-bundles/${NEW_BUNDLE_ID}" >/dev/null 2>&1 || true
            else
                curl -sk -X DELETE -u "${ACS_PORTAL_USERNAME}:${ADMIN_PASSWORD}" "${CENTRAL_API_URL}/v1/cluster-init/init-bundles/${NEW_BUNDLE_ID}" >/dev/null 2>&1 || true
            fi
            sleep 2
        fi
        error "Please run the script again after deleting the init bundle in Central UI or wait for automatic cleanup"
    else
        log "✓ Init bundle appears to contain valid certificate data (no wildcard IDs detected)"
    fi
else
    error "Init bundle file does not appear to contain valid Secret resources"
fi

    log "✓ Init bundle generated and saved to: $INIT_BUNDLE_FILE"
else
    log "✓ Using provided init bundle file (skipped generation)"
fi

# Now switch to aws-us cluster for deployment
log "Switching to aws-us context for deployment..."
$KUBECTL_CMD config use-context aws-us >/dev/null 2>&1 || error "Failed to switch to aws-us context"
log "✓ Switched to aws-us context"

# Check if SecuredCluster actually exists and operator is properly installed
SECURED_CLUSTER_EXISTS=false
OPERATOR_INSTALLED=false

# Check if SecuredCluster CRD exists (operator must be installed)
if $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
    OPERATOR_INSTALLED=true
    log "SecuredCluster CRD found, operator appears to be installed"
    
    # Check if operator pods are actually running
    CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
    if [ -n "$CSV_NAME" ] && [ "$CSV_NAME" != "" ]; then
        CSV_PHASE=$($KUBECTL_CMD get csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$CSV_PHASE" = "Succeeded" ]; then
            log "Operator CSV is in Succeeded phase"
        else
            log "Operator CSV phase: ${CSV_PHASE:-unknown}, operator may not be fully installed"
            OPERATOR_INSTALLED=false
        fi
    else
        log "No operator CSV found, operator is not installed"
        OPERATOR_INSTALLED=false
    fi
    
    # Only check for SecuredCluster if operator is actually installed
    if [ "$OPERATOR_INSTALLED" = "true" ]; then
        if $KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            # Check if it's being deleted
            DELETION_TIMESTAMP=$($KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")
            if [ -n "$DELETION_TIMESTAMP" ] && [ "$DELETION_TIMESTAMP" != "" ]; then
                log "SecuredCluster exists but is being deleted, will recreate"
                SECURED_CLUSTER_EXISTS=false
            else
                SECURED_CLUSTER_EXISTS=true
            fi
        fi
    fi
else
    log "SecuredCluster CRD not found, operator is not installed"
fi

# Proceed with operator installation if needed
if [ "$SECURED_CLUSTER_EXISTS" != "true" ] || [ "$OPERATOR_INSTALLED" != "true" ]; then
    # Ensure namespace exists in aws-us cluster
    log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists in aws-us cluster..."
    if ! $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        $KUBECTL_CMD create namespace "$RHACS_OPERATOR_NAMESPACE" || error "Failed to create namespace"
        log "✓ Operator namespace created"
    else
        log "✓ Operator namespace exists"
    fi

    # Check if SecuredCluster CRD exists and operator is properly installed, install operator if needed
    log "Checking if SecuredCluster CRD is installed..."
    CRD_EXISTS=false
    if $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
        CRD_EXISTS=true
        log "SecuredCluster CRD found"
    fi
    
    # Check if operator is actually installed (CSV exists and is Succeeded)
    NEED_OPERATOR_INSTALL=true
    if [ "$CRD_EXISTS" = "true" ]; then
        CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
        if [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "" ]; then
            CSV_NAME=$($KUBECTL_CMD get csv -n openshift-operators 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
        fi
        if [ -n "$CSV_NAME" ] && [ "$CSV_NAME" != "" ]; then
            CSV_PHASE=$($KUBECTL_CMD get csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ -z "$CSV_PHASE" ] || [ "$CSV_PHASE" = "" ]; then
                CSV_PHASE=$($KUBECTL_CMD get csv "$CSV_NAME" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            fi
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                log "Operator CSV is installed and in Succeeded phase"
                NEED_OPERATOR_INSTALL=false
            else
                log "Operator CSV exists but phase is '${CSV_PHASE:-unknown}', operator may need reinstallation"
            fi
        else
            log "CRD exists but no operator CSV found, operator needs to be installed"
        fi
    fi
    
    if [ "$NEED_OPERATOR_INSTALL" = "true" ]; then
        if [ "$CRD_EXISTS" = "false" ]; then
            log "SecuredCluster CRD not found. Installing RHACS operator..."
        else
            log "SecuredCluster CRD exists but operator is not properly installed. Installing RHACS operator..."
        fi
        
        # Verify namespace exists
        if ! $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            error "Namespace '$RHACS_OPERATOR_NAMESPACE' does not exist. Cannot install operator."
        fi
        
        # Create OperatorGroup if it doesn't exist
        if ! $KUBECTL_CMD get operatorgroup rhacs-operator-group -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            log "Creating OperatorGroup..."
            if ! cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhacs-operator-group
  namespace: $RHACS_OPERATOR_NAMESPACE
spec: {}
EOF
            then
                error "Failed to create OperatorGroup"
            fi
            log "✓ OperatorGroup created (cluster-wide)"
        else
            log "✓ OperatorGroup already exists"
        fi
        
        # Create Subscription for RHACS operator
        log "Creating RHACS operator subscription..."
        SUBSCRIPTION_YAML=$(cat <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhacs-operator
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  channel: stable
  name: rhacs-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
)
        if ! echo "$SUBSCRIPTION_YAML" | $KUBECTL_CMD apply -f -; then
            error "Failed to create RHACS operator subscription"
        fi
        
        # Verify subscription was created with explicit API group
        log "Verifying subscription was created..."
        sleep 3
        if ! $KUBECTL_CMD get subscription.operators.coreos.com rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            warning "Subscription not found with explicit API group, checking without..."
            if ! $KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                error "Subscription 'rhacs-operator' not found in namespace '$RHACS_OPERATOR_NAMESPACE' after creation. Check operator installation manually."
            fi
        fi
        log "✓ Operator subscription created and verified"
        
        # Check subscription status and InstallPlan
        log "Checking subscription status..."
        sleep 5  # Give subscription time to create InstallPlan
        SUBSCRIPTION_STATUS=$($KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
        INSTALL_PLAN=$($KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || echo "")
        log "Subscription state: ${SUBSCRIPTION_STATUS:-unknown}"
        if [ -n "$INSTALL_PLAN" ] && [ "$INSTALL_PLAN" != "null" ] && [ "$INSTALL_PLAN" != "" ]; then
            log "InstallPlan: $INSTALL_PLAN"
            INSTALL_PLAN_PHASE=$($KUBECTL_CMD get installplan "$INSTALL_PLAN" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ -n "$INSTALL_PLAN_PHASE" ]; then
                log "InstallPlan phase: $INSTALL_PLAN_PHASE"
            fi
        else
            log "Waiting for InstallPlan to be created..."
        fi
        
        # Check if CSV already exists before waiting
        CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
        if [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "null" ] || [ "$CSV_NAME" = "" ]; then
            CSV_NAME=$($KUBECTL_CMD get csv -n openshift-operators 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
        fi
        
        # Wait for CSV to be installed first (if not already found)
        if [ -n "$CSV_NAME" ] && [ "$CSV_NAME" != "null" ] && [ "$CSV_NAME" != "" ]; then
            log "✓ Operator CSV already exists: $CSV_NAME"
        else
            log "Waiting for RHACS operator CSV to be installed..."
            csv_wait_count=0
            csv_max_wait=300
            CSV_NAME=""
            while [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "null" ] || [ "$CSV_NAME" = "" ]; do
            if [ $csv_wait_count -ge $csv_max_wait ]; then
                warning "Timeout waiting for operator CSV. Checking subscription and InstallPlan status..."
                $KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o yaml 2>/dev/null | grep -A 15 "status:" || true
                INSTALL_PLAN=$($KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || echo "")
                if [ -n "$INSTALL_PLAN" ] && [ "$INSTALL_PLAN" != "null" ]; then
                    log "Checking InstallPlan $INSTALL_PLAN..."
                    $KUBECTL_CMD get installplan "$INSTALL_PLAN" -n "$RHACS_OPERATOR_NAMESPACE" -o yaml 2>/dev/null | grep -A 20 "status:" || true
                fi
                log "Checking for CSV in rhacs-operator namespace..."
                $KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null || true
                log "Checking for CSV in openshift-operators namespace..."
                $KUBECTL_CMD get csv -n openshift-operators 2>/dev/null | grep rhacs || true
                error "Operator CSV installation timeout. Please check operator installation manually."
            fi
            # Check both rhacs-operator and openshift-operators namespaces for CSV
            # Use simpler approach: get all CSVs and filter for rhacs-operator (skip header)
            CSV_NAME=$($KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
            if [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "null" ] || [ "$CSV_NAME" = "" ]; then
                CSV_NAME=$($KUBECTL_CMD get csv -n openshift-operators 2>/dev/null | grep -v "^NAME" | grep -E "rhacs-operator\." | awk '{print $1}' | head -1 || echo "")
            fi
            sleep 2
            csv_wait_count=$((csv_wait_count + 1))
            if [ $((csv_wait_count % 20)) -eq 0 ]; then
                log "  Still waiting for CSV... ($csv_wait_count/${csv_max_wait}s)"
                # Debug: show what CSVs we found
                if [ $csv_wait_count -eq 20 ]; then
                    log "  Available CSVs in $RHACS_OPERATOR_NAMESPACE:"
                    $KUBECTL_CMD get csv -n "$RHACS_OPERATOR_NAMESPACE" 2>/dev/null | head -5 || true
                fi
                # Check InstallPlan status periodically
                INSTALL_PLAN=$($KUBECTL_CMD get subscription rhacs-operator -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || echo "")
                if [ -n "$INSTALL_PLAN" ] && [ "$INSTALL_PLAN" != "null" ]; then
                    INSTALL_PLAN_PHASE=$($KUBECTL_CMD get installplan "$INSTALL_PLAN" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                    if [ -n "$INSTALL_PLAN_PHASE" ]; then
                        log "  InstallPlan phase: $INSTALL_PLAN_PHASE"
                    fi
                fi
            fi
            done
            log "✓ Operator CSV found: $CSV_NAME"
        fi
        
        # Determine which namespace the CSV is in
        CSV_NAMESPACE="$RHACS_OPERATOR_NAMESPACE"
        if ! $KUBECTL_CMD get csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            CSV_NAMESPACE="openshift-operators"
        fi
        log "CSV is in namespace: $CSV_NAMESPACE"
        
        # Wait for CSV to be in Succeeded phase
        log "Waiting for operator CSV to be ready..."
        csv_ready_wait_count=0
        csv_ready_max_wait=600  # Increased to 10 minutes for single-node clusters
        while true; do
            CSV_PHASE=$($KUBECTL_CMD get csv "$CSV_NAME" -n "$CSV_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [ "$CSV_PHASE" = "Succeeded" ]; then
                break
            fi
            
            # Check for stuck installation states
            CSV_MESSAGE=$($KUBECTL_CMD get csv "$CSV_NAME" -n "$CSV_NAMESPACE" -o jsonpath='{.status.message}' 2>/dev/null || echo "")
            if [ -n "$CSV_MESSAGE" ] && [[ "$CSV_MESSAGE" == *"not available"* ]] || [[ "$CSV_MESSAGE" == *"minimum availability"* ]]; then
                if [ $((csv_ready_wait_count % 60)) -eq 0 ]; then
                    warning "Operator installation appears stuck: $CSV_MESSAGE"
                    log "Checking operator deployment status..."
                    $KUBECTL_CMD get deployment rhacs-operator-controller-manager -n "$CSV_NAMESPACE" -o yaml 2>/dev/null | grep -A 10 "status:" || true
                    log "Checking operator pods..."
                    $KUBECTL_CMD get pods -n "$CSV_NAMESPACE" | grep rhacs-operator || true
                fi
            fi
            
            if [ $csv_ready_wait_count -ge $csv_ready_max_wait ]; then
                warning "Timeout waiting for CSV to be ready. Current phase: ${CSV_PHASE:-unknown}"
                if [ -n "$CSV_MESSAGE" ]; then
                    warning "CSV message: $CSV_MESSAGE"
                fi
                log "CSV status details:"
                $KUBECTL_CMD get csv "$CSV_NAME" -n "$CSV_NAMESPACE" -o yaml 2>/dev/null | grep -A 30 "status:" || true
                log "Operator deployment status:"
                $KUBECTL_CMD get deployment rhacs-operator-controller-manager -n "$CSV_NAMESPACE" 2>/dev/null || log "Deployment not found"
                log "Operator pods:"
                $KUBECTL_CMD get pods -n "$CSV_NAMESPACE" | grep rhacs-operator || log "No operator pods found"
                warning "Operator CSV installation timeout. The operator may need manual intervention."
                warning "You may need to check resource constraints, node availability, or operator subscription issues."
                error "Please check operator installation manually and retry."
            fi
            sleep 2
            csv_ready_wait_count=$((csv_ready_wait_count + 1))
            if [ $((csv_ready_wait_count % 30)) -eq 0 ]; then
                log "  Still waiting for CSV to be ready... ($csv_ready_wait_count/${csv_ready_max_wait}s) - Phase: ${CSV_PHASE:-pending}"
                if [ -n "$CSV_MESSAGE" ]; then
                    log "  Status: $CSV_MESSAGE"
                fi
            fi
        done
        log "✓ Operator CSV is ready"
        
        # Wait for CRD to be available (only if it doesn't already exist)
        if ! $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
            log "Waiting for SecuredCluster CRD to be installed..."
            wait_count=0
            max_wait=120
            while ! $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; do
                if [ $wait_count -ge $max_wait ]; then
                    warning "Timeout waiting for SecuredCluster CRD to be installed"
                    warning "Checking operator installation status..."
                    CSV_NAMESPACE="$RHACS_OPERATOR_NAMESPACE"
                    if ! $KUBECTL_CMD get csv "$CSV_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                        CSV_NAMESPACE="openshift-operators"
                    fi
                    $KUBECTL_CMD get csv "$CSV_NAME" -n "$CSV_NAMESPACE" -o yaml 2>/dev/null | grep -A 20 "status:" || true
                    error "SecuredCluster CRD installation timeout. Please check operator installation manually."
                fi
                sleep 2
                wait_count=$((wait_count + 1))
                if [ $((wait_count % 20)) -eq 0 ]; then
                    log "  Still waiting for CRD... ($wait_count/${max_wait}s)"
                fi
            done
            log "✓ SecuredCluster CRD installed"
        else
            log "✓ SecuredCluster CRD already exists"
        fi
    else
        log "✓ Operator is already installed, skipping operator installation"
    fi
fi

# Always ensure namespace exists and apply SecuredCluster configuration
# Ensure namespace exists in aws-us cluster
log "Ensuring namespace '$RHACS_OPERATOR_NAMESPACE' exists in aws-us cluster..."
if ! $KUBECTL_CMD get namespace "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
    $KUBECTL_CMD create namespace "$RHACS_OPERATOR_NAMESPACE" || error "Failed to create namespace"
    log "✓ Operator namespace created"
else
    log "✓ Operator namespace exists"
fi

# Verify operator is installed before proceeding
if ! $KUBECTL_CMD get crd securedclusters.platform.stackrox.io >/dev/null 2>&1; then
    error "SecuredCluster CRD not found. Operator must be installed first. Please run the script again to install the operator."
fi

# Apply init bundle secrets to aws-us cluster
# CRITICAL: Apply init bundle BEFORE creating SecuredCluster to avoid race conditions
if [ -f "$INIT_BUNDLE_FILE" ]; then
    log "Applying init bundle secrets to aws-us cluster from: $INIT_BUNDLE_FILE"
    log "NOTE: Init bundle must be applied BEFORE SecuredCluster creation to avoid certificate race conditions"
    
    # If SecuredCluster exists, delete it first to force fresh registration with new certs
    # This prevents the wildcard cert issue where sensor panics before completing registration
    if $KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        log "Deleting existing SecuredCluster to force fresh registration with new init bundle..."
        log "  (This prevents wildcard cert issues that cause sensor panic - Red Hat Solution 6972449)"
        $KUBECTL_CMD delete securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || true
        sleep 5
        # Wait for it to be fully deleted
        DELETE_WAIT=0
        while $KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; do
            if [ $DELETE_WAIT -ge 30 ]; then
                warning "SecuredCluster still exists, removing finalizers..."
                $KUBECTL_CMD patch securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                break
            fi
            sleep 2
            DELETE_WAIT=$((DELETE_WAIT + 2))
        done
        log "✓ SecuredCluster deleted, will be recreated with fresh init bundle"
    fi
    
    # CRITICAL: Fully clean up existing secrets to prevent wildcard cert issues
    # This addresses Red Hat Solution 6972449 - stale init bundle secrets cause sensor panic
    log "Cleaning up existing init bundle secrets to prevent wildcard cert issues..."
    REQUIRED_SECRETS=("sensor-tls" "admission-control-tls" "collector-tls")
    for secret in "${REQUIRED_SECRETS[@]}"; do
        if $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            log "  Deleting existing secret $secret (may contain wildcard cert)..."
            # Force delete to ensure complete cleanup
            $KUBECTL_CMD delete secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true --grace-period=0 2>/dev/null || true
            # Wait a moment for deletion to complete
            sleep 2
            # Verify deletion
            if $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                warning "Secret $secret still exists after deletion, forcing removal..."
                $KUBECTL_CMD patch secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                $KUBECTL_CMD delete secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" --force --grace-period=0 2>/dev/null || true
                sleep 1
            fi
        fi
    done
    
    # Also check for any pods using these secrets and wait for them to be cleaned up
    log "Waiting for pods using old secrets to be cleaned up..."
    sleep 3
    log "✓ Old secrets cleaned up, ready for fresh init bundle"
    
    # CRITICAL: Validate init bundle doesn't contain wildcard IDs before applying
    # This prevents the panic error: "Invalid dynamic cluster ID value "" : no concrete cluster ID"
    log "Validating init bundle for wildcard IDs (Red Hat Solution 6972449)..."
    if grep -q "00000000-0000-0000-0000-000000000000" "$INIT_BUNDLE_FILE" 2>/dev/null; then
        error "Init bundle contains wildcard ID '00000000-0000-0000-0000-000000000000' - this will cause sensor panic!"
        error "Please regenerate the init bundle in Central and ensure it has a concrete cluster ID."
        error "Init bundle file: $INIT_BUNDLE_FILE"
    fi
    
    # Check if init bundle appears to be empty or invalid
    if ! grep -q "kind: Secret" "$INIT_BUNDLE_FILE" 2>/dev/null; then
        error "Init bundle file does not contain valid Secret resources: $INIT_BUNDLE_FILE"
    fi
    
    # Verify init bundle has actual certificate data (not just empty data fields)
    if grep -q "data:" "$INIT_BUNDLE_FILE" 2>/dev/null; then
        # Check if data fields are empty
        if grep -A 5 "data:" "$INIT_BUNDLE_FILE" 2>/dev/null | grep -qE "^[[:space:]]*[a-zA-Z-]+:[[:space:]]*$"; then
            warning "Init bundle may have empty data fields - this can cause issues"
        fi
    fi
    
    log "✓ Init bundle validation passed - no wildcard IDs detected"
    
    # Apply init bundle
    if ! $KUBECTL_CMD apply -f "$INIT_BUNDLE_FILE" -n "$RHACS_OPERATOR_NAMESPACE"; then
        error "Failed to apply init bundle secrets. Check the init bundle file: $INIT_BUNDLE_FILE"
    fi
    log "✓ Init bundle secrets applied"
    
    # Wait and verify the secrets were fully created (not just applied)
    log "Waiting for init bundle secrets to be fully created and verified..."
    REQUIRED_SECRETS=("sensor-tls" "admission-control-tls" "collector-tls")
    SECRET_WAIT_COUNT=0
    SECRET_MAX_WAIT=60
    ALL_SECRETS_READY=false
    
    while [ $SECRET_WAIT_COUNT -lt $SECRET_MAX_WAIT ]; do
        MISSING_SECRETS=()
        EMPTY_SECRETS=()
        
        for secret in "${REQUIRED_SECRETS[@]}"; do
            if ! $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                MISSING_SECRETS+=("$secret")
            else
                # Verify secret has data
                SECRET_DATA=$($KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data}' 2>/dev/null || echo "")
                if [ -z "$SECRET_DATA" ] || [ "$SECRET_DATA" = "{}" ]; then
                    EMPTY_SECRETS+=("$secret")
                fi
            fi
        done
        
        if [ ${#MISSING_SECRETS[@]} -eq 0 ] && [ ${#EMPTY_SECRETS[@]} -eq 0 ]; then
            ALL_SECRETS_READY=true
            break
        fi
        
        sleep 2
        SECRET_WAIT_COUNT=$((SECRET_WAIT_COUNT + 2))
        
        if [ $((SECRET_WAIT_COUNT % 10)) -eq 0 ]; then
            if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
                log "  Still waiting for secrets: ${MISSING_SECRETS[*]}"
            fi
            if [ ${#EMPTY_SECRETS[@]} -gt 0 ]; then
                log "  Secrets exist but empty: ${EMPTY_SECRETS[*]}"
            fi
        fi
    done
    
    if [ "$ALL_SECRETS_READY" = "false" ]; then
        if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
            error "Timeout waiting for init bundle secrets to be created: ${MISSING_SECRETS[*]}. Check the init bundle file: $INIT_BUNDLE_FILE"
        fi
        if [ ${#EMPTY_SECRETS[@]} -gt 0 ]; then
            error "Init bundle secrets exist but are empty: ${EMPTY_SECRETS[*]}. The init bundle may be corrupted. Regenerate it."
        fi
    fi
    
    log "✓ All required secrets verified and ready: ${REQUIRED_SECRETS[*]}"
    log "  All secrets contain certificate data and are ready for use"
    
    # Additional verification: ensure secrets are in the correct namespace
    log "Verifying secrets are in the correct namespace: $RHACS_OPERATOR_NAMESPACE"
    for secret in "${REQUIRED_SECRETS[@]}"; do
        SECRET_NAMESPACE=$($KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.namespace}' 2>/dev/null || echo "")
        if [ "$SECRET_NAMESPACE" != "$RHACS_OPERATOR_NAMESPACE" ]; then
            warning "Secret $secret is in namespace '$SECRET_NAMESPACE' but should be in '$RHACS_OPERATOR_NAMESPACE'"
        fi
    done
    
    log "Init bundle saved at: $INIT_BUNDLE_FILE (kept for reference)"
else
    # Try to find any existing init bundle file for this cluster
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    INIT_BUNDLES_DIR="${SCRIPT_DIR}/init-bundles"
    EXISTING_BUNDLE=$(find "$INIT_BUNDLES_DIR" -name "${CLUSTER_NAME}-init-bundle*.yaml" 2>/dev/null | head -1)
    if [ -n "$EXISTING_BUNDLE" ] && [ -f "$EXISTING_BUNDLE" ]; then
        log "Found existing init bundle file: $EXISTING_BUNDLE"
        log "Applying init bundle secrets to aws-us cluster..."
        
        # Clean up existing secrets first (same as above)
        log "Cleaning up any existing init bundle secrets..."
        for secret in sensor-tls admission-control-tls collector-tls; do
            if $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                log "  Deleting existing secret $secret..."
                $KUBECTL_CMD delete secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" --ignore-not-found=true || true
                sleep 1
            fi
        done
        
        if ! $KUBECTL_CMD apply -f "$EXISTING_BUNDLE" -n "$RHACS_OPERATOR_NAMESPACE"; then
            error "Failed to apply existing init bundle secrets. Regenerate the init bundle: $EXISTING_BUNDLE"
        fi
        
        # Use same robust verification as above
        log "Waiting for init bundle secrets to be fully created..."
        REQUIRED_SECRETS=("sensor-tls" "admission-control-tls" "collector-tls")
        SECRET_WAIT_COUNT=0
        SECRET_MAX_WAIT=60
        ALL_SECRETS_READY=false
        
        while [ $SECRET_WAIT_COUNT -lt $SECRET_MAX_WAIT ]; do
            MISSING_SECRETS=()
            EMPTY_SECRETS=()
            
            for secret in "${REQUIRED_SECRETS[@]}"; do
                if ! $KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                    MISSING_SECRETS+=("$secret")
                else
                    SECRET_DATA=$($KUBECTL_CMD get secret "$secret" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data}' 2>/dev/null || echo "")
                    if [ -z "$SECRET_DATA" ] || [ "$SECRET_DATA" = "{}" ]; then
                        EMPTY_SECRETS+=("$secret")
                    fi
                fi
            done
            
            if [ ${#MISSING_SECRETS[@]} -eq 0 ] && [ ${#EMPTY_SECRETS[@]} -eq 0 ]; then
                ALL_SECRETS_READY=true
                break
            fi
            
            sleep 2
            SECRET_WAIT_COUNT=$((SECRET_WAIT_COUNT + 2))
        done
        
        if [ "$ALL_SECRETS_READY" = "false" ]; then
            if [ ${#MISSING_SECRETS[@]} -gt 0 ]; then
                error "Timeout waiting for init bundle secrets: ${MISSING_SECRETS[*]}. Regenerate the init bundle."
            fi
            if [ ${#EMPTY_SECRETS[@]} -gt 0 ]; then
                error "Init bundle secrets are empty: ${EMPTY_SECRETS[*]}. The init bundle may be corrupted. Regenerate it."
            fi
        fi
        
        log "✓ All required secrets verified and ready: ${REQUIRED_SECRETS[*]}"
    else
        error "Init bundle file not found. Cannot proceed without init bundle secrets."
        error "Expected location: $INIT_BUNDLE_FILE"
        error "Please ensure the init bundle is generated before creating the SecuredCluster."
    fi
fi

# Create or update SecuredCluster resource in aws-us cluster (optimized for single-node)
if [ "$SECURED_CLUSTER_EXISTS" = "true" ]; then
    log "Updating existing SecuredCluster resource for single-node optimization..."
else
    log "Creating SecuredCluster resource in aws-us cluster (optimized for single-node)..."
fi

# Construct Central endpoint for SecuredCluster - must be in host:port format (no protocol, no path)
# ROX_ENDPOINT was set earlier when we were on local-cluster context
# Ensure it's properly normalized for the SecuredCluster centralEndpoint field
if [ -z "${ROX_ENDPOINT_NORMALIZED:-}" ]; then
    # Normalize ROX_ENDPOINT: ensure it's host:port format
    CENTRAL_ENDPOINT="${ROX_ENDPOINT}"
    # Strip any remaining path (should already be done, but be safe)
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%%/*}"
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%/}"
    # Ensure port is present
    if [[ "$CENTRAL_ENDPOINT" != *:* ]]; then
        CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT}:443"
    fi
else
    CENTRAL_ENDPOINT="${ROX_ENDPOINT_NORMALIZED}"
fi

# Final validation: ensure endpoint is in correct format for SecuredCluster (host:port only)
if [[ "$CENTRAL_ENDPOINT" == *"://"* ]]; then
    warning "Central endpoint contains protocol, stripping: $CENTRAL_ENDPOINT"
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT#*://}"
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%%/*}"
fi
if [[ "$CENTRAL_ENDPOINT" == *"/"* ]]; then
    warning "Central endpoint contains path, stripping: $CENTRAL_ENDPOINT"
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT%%/*}"
fi
if [[ "$CENTRAL_ENDPOINT" != *:* ]]; then
    CENTRAL_ENDPOINT="${CENTRAL_ENDPOINT}:443"
fi

log "Configuring SecuredCluster centralEndpoint: $CENTRAL_ENDPOINT"
log "  (This is the API endpoint the sensor will use to connect to Central)"

# Get cluster ID from OpenShift clusterversion to ensure concrete cluster ID
# This prevents the wildcard ID panic issue (Red Hat Solution 6972449)
log "Detecting cluster ID from OpenShift clusterversion..."
CLUSTER_ID=""
if $KUBECTL_CMD get clusterversion version >/dev/null 2>&1; then
    CLUSTER_ID=$($KUBECTL_CMD get clusterversion version -o jsonpath='{.spec.clusterID}' 2>/dev/null || echo "")
    if [ -n "$CLUSTER_ID" ] && [ "$CLUSTER_ID" != "null" ] && [ "$CLUSTER_ID" != "" ]; then
        log "✓ Detected cluster ID from clusterversion: $CLUSTER_ID"
        log "  (This ensures sensor uses concrete cluster ID instead of wildcard)"
    else
        warning "Could not retrieve cluster ID from clusterversion - sensor will auto-detect"
    fi
else
    warning "clusterversion resource not found - sensor will auto-detect cluster ID"
fi

cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: platform.stackrox.io/v1alpha1
kind: SecuredCluster
metadata:
  name: $SECURED_CLUSTER_NAME
  namespace: $RHACS_OPERATOR_NAMESPACE
spec:
  clusterName: "$CLUSTER_NAME"
  centralEndpoint: "$CENTRAL_ENDPOINT"
  auditLogs:
    collection: Auto
  admissionControl:
    enforcement: Enabled
    bypass: BreakGlassAnnotation
    failurePolicy: Ignore
    dynamic:
      disableBypass: false
    replicas: 1
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
  scanner:
    scannerComponent: Disabled
  scannerV4:
    scannerComponent: AutoSense
    indexer:
      replicas: 1
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
  collector:
    collectionMethod: KernelModule
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
  sensor:
    tolerations:
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      - key: node-role.kubernetes.io/infra
        operator: Exists
        effect: NoSchedule
  processBaselines:
    autoLock: Enabled
EOF
    
if [ "$SECURED_CLUSTER_EXISTS" = "true" ]; then
    log "✓ SecuredCluster resource updated"
else
    log "✓ SecuredCluster resource created"
fi

# Handle operator reconciliation glitches after install/delete cycles
log "Checking for operator reconciliation issues..."
# Check if SecuredCluster has deletion timestamp (stuck in deletion)
DELETION_TIMESTAMP=$($KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")
if [ -n "$DELETION_TIMESTAMP" ] && [ "$DELETION_TIMESTAMP" != "" ]; then
    warning "SecuredCluster has deletion timestamp - it may be stuck from a previous install/delete cycle"
    warning "Removing finalizers to allow cleanup..."
    $KUBECTL_CMD patch securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    sleep 5
    
    # Wait for it to be fully deleted, then it will be recreated by the apply above
    DELETE_WAIT=0
    while $KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; do
        if [ $DELETE_WAIT -ge 30 ]; then
            warning "SecuredCluster still exists after removing finalizers. Forcing deletion..."
            $KUBECTL_CMD delete securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" --force --grace-period=0 2>/dev/null || true
            break
        fi
        sleep 2
        DELETE_WAIT=$((DELETE_WAIT + 2))
    done
    
    log "SecuredCluster cleaned up, will be recreated by operator"
    sleep 3
fi

# Check for stuck pods from previous installations
log "Checking for stuck pods from previous installations..."
STUCK_PODS=$($KUBECTL_CMD get pods -n "$RHACS_OPERATOR_NAMESPACE" --field-selector=status.phase!=Running,status.phase!=Succeeded -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "$STUCK_PODS" ]; then
    for pod in $STUCK_PODS; do
        POD_AGE=$($KUBECTL_CMD get pod "$pod" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || echo "")
        # Only clean up pods older than 5 minutes (to avoid deleting newly created ones)
        if [ -n "$POD_AGE" ]; then
            log "  Found potentially stuck pod: $pod (created: $POD_AGE)"
        fi
    done
fi

# Wait for operator to start reconciling
log "Waiting for operator to reconcile SecuredCluster resource..."
sleep 5

# Wait for sensor deployment to be created and ready (indicates connection to Central)
log "Waiting for sensor to be created and connect to Central..."
SENSOR_WAIT_COUNT=0
SENSOR_MAX_WAIT=300
SENSOR_READY=false

while [ $SENSOR_WAIT_COUNT -lt $SENSOR_MAX_WAIT ]; do
    # Check if sensor deployment exists
    if $KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
        # Check if sensor pod is running and ready
        SENSOR_READY_REPLICAS=$($KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        SENSOR_REPLICAS=$($KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        
        if [ "$SENSOR_REPLICAS" != "0" ] && [ "$SENSOR_READY_REPLICAS" = "$SENSOR_REPLICAS" ]; then
            # Check if sensor pod has connected to Central (no init-tls-certs errors)
            SENSOR_POD=$($KUBECTL_CMD get pods -n "$RHACS_OPERATOR_NAMESPACE" -l app=sensor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$SENSOR_POD" ] && [ "$SENSOR_POD" != "" ]; then
                # Check pod status - if it's Running, sensor likely connected
                POD_PHASE=$($KUBECTL_CMD get pod "$SENSOR_POD" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$POD_PHASE" = "Running" ]; then
                    # Check for init-tls-certs container errors
                    INIT_TLS_ERRORS=$($KUBECTL_CMD logs "$SENSOR_POD" -n "$RHACS_OPERATOR_NAMESPACE" -c init-tls-certs 2>&1 | grep -i "error\|failed\|timeout" | wc -l || echo "0")
                    if [ "$INIT_TLS_ERRORS" = "0" ] || [ -z "$INIT_TLS_ERRORS" ]; then
                        SENSOR_READY=true
                        break
                    fi
                fi
            fi
        fi
    fi
    
    sleep 5
    SENSOR_WAIT_COUNT=$((SENSOR_WAIT_COUNT + 5))
    
    if [ $((SENSOR_WAIT_COUNT % 30)) -eq 0 ]; then
        log "  Still waiting for sensor to connect to Central... (${SENSOR_WAIT_COUNT}/${SENSOR_MAX_WAIT}s)"
        if $KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
            SENSOR_STATUS=$($KUBECTL_CMD get deployment sensor -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
            log "  Sensor deployment status: ${SENSOR_STATUS:-unknown}"
        fi
    fi
done

if [ "$SENSOR_READY" = "true" ]; then
    log "✓ Sensor is running and connected to Central"
else
    warning "Sensor may not be fully ready yet. This is normal for SNO clusters - sensor will continue connecting in the background."
    warning "Monitor sensor pod logs if connection issues persist: oc logs -n $RHACS_OPERATOR_NAMESPACE -l app=sensor"
fi

# Verify Scanner V4 is enabled with minimal configuration
log "Verifying Scanner V4 configuration..."
SCANNER_V4_COMPONENT=$($KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.scannerV4.scannerComponent}' 2>/dev/null || echo "")
SCANNER_V4_INDEXER_REPLICAS=$($KUBECTL_CMD get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.scannerV4.indexer.replicas}' 2>/dev/null || echo "")
if [ "$SCANNER_V4_COMPONENT" = "Default" ] || [ "$SCANNER_V4_COMPONENT" = "AutoSense" ]; then
    if [ "$SCANNER_V4_INDEXER_REPLICAS" = "1" ]; then
        log "✓ Scanner V4 is enabled with minimal configuration (AutoSense mode, indexer: 1 replica, appropriate for single-node cluster)"
    else
        log "✓ Scanner V4 is enabled (component: ${SCANNER_V4_COMPONENT}, indexer replicas: ${SCANNER_V4_INDEXER_REPLICAS:-default})"
        if [ "$SCANNER_V4_INDEXER_REPLICAS" != "1" ] && [ -n "$SCANNER_V4_INDEXER_REPLICAS" ]; then
            warning "Scanner V4 indexer has ${SCANNER_V4_INDEXER_REPLICAS} replica(s) - consider setting to 1 for single-node clusters"
        fi
    fi
else
    warning "Scanner V4 component: ${SCANNER_V4_COMPONENT:-unknown} (expected: Default or AutoSense)"
fi

log "Secured Cluster Services deployment initiated for aws-us cluster"
log "The SecuredCluster will connect to Central running on local-cluster"
log ""
log "IMPORTANT NOTES:"
log "  - Init bundle secrets are applied in namespace: $RHACS_OPERATOR_NAMESPACE"
log "  - Central endpoint configured: $CENTRAL_ENDPOINT"
if [ -n "$CLUSTER_ID" ] && [ "$CLUSTER_ID" != "" ]; then
    log "  - Cluster ID detected: $CLUSTER_ID (sensor will use concrete cluster ID)"
else
    log "  - Cluster ID: Sensor will auto-detect from OpenShift clusterversion"
fi
log "  - Scanner V4 is enabled with minimal configuration (1 replica, optimized for single-node)"
log "  - Init bundle validated: No wildcard IDs detected (prevents sensor panic - Red Hat Solution 6972449)"
log "  - If pods fail to start, check init bundle secrets and sensor connection"
log "  - Monitor pod logs: oc logs -n $RHACS_OPERATOR_NAMESPACE <pod-name> -c init-tls-certs"
log "  - If you see 'Invalid dynamic cluster ID' panic, ensure init bundle doesn't contain wildcard ID"

log "ACS setup complete"
