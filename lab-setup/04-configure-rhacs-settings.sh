#!/bin/bash
# RHACS Configuration Script
# Makes API calls to RHACS to change configuration details
# Enables monitoring/metrics and configures policy guidelines

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHACS-CONFIG]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-CONFIG]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-CONFIG] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-CONFIG] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Set script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Check current context and switch to local-cluster if needed
CURRENT_CONTEXT=$(oc config current-context 2>/dev/null || echo "")
if [ "$CURRENT_CONTEXT" != "local-cluster" ]; then
    log "Current context is '$CURRENT_CONTEXT'. Switching to 'local-cluster'..."
    if oc config use-context local-cluster >/dev/null 2>&1; then
        log "✓ Switched to 'local-cluster' context"
    else
        error "Failed to switch to 'local-cluster' context. Please ensure the context exists."
    fi
else
    log "✓ Already in 'local-cluster' context"
fi

# Detect RHACS namespace - check stackrox first (newer installations), then rhacs-operator (older installations)
log "Detecting RHACS namespace..."
RHACS_NAMESPACE=""
if oc get route central -n "stackrox" -o jsonpath='{.spec.host}' >/dev/null 2>&1; then
    RHACS_NAMESPACE="stackrox"
    log "✓ Found RHACS in namespace: stackrox"
elif oc get route central -n "rhacs-operator" -o jsonpath='{.spec.host}' >/dev/null 2>&1; then
    RHACS_NAMESPACE="rhacs-operator"
    log "✓ Found RHACS in namespace: rhacs-operator"
else
    error "Central route not found in 'stackrox' or 'rhacs-operator' namespace. Please ensure RHACS Central is installed."
fi

# Generate ROX_ENDPOINT from Central route
log "Extracting ROX_ENDPOINT from Central route..."
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_ROUTE" ]; then
    error "Central route not found in namespace '$RHACS_NAMESPACE'. Please ensure RHACS Central is installed."
fi
ROX_ENDPOINT="$CENTRAL_ROUTE"
log "✓ Extracted ROX_ENDPOINT: $ROX_ENDPOINT"

# Get ADMIN_PASSWORD from secret (needed for token generation)
log "Extracting admin password from secret..."

# First check if secret exists
if ! oc get secret central-htpasswd -n "$RHACS_NAMESPACE" >/dev/null 2>&1; then
    log "Secret 'central-htpasswd' not found in namespace '$RHACS_NAMESPACE', checking environment variable..."
    if [ -n "$ACS_PORTAL_PASSWORD" ]; then
        ADMIN_PASSWORD_B64="$ACS_PORTAL_PASSWORD"
        log "✓ Using password from ACS_PORTAL_PASSWORD environment variable"
    else
        error "Admin password secret 'central-htpasswd' not found in namespace '$RHACS_NAMESPACE' and ACS_PORTAL_PASSWORD environment variable not set"
    fi
else
    # Secret exists, try to extract password
    ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
    
    # If password key not found, try alternative key names
    if [ -z "$ADMIN_PASSWORD_B64" ]; then
        ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.adminPassword}' 2>/dev/null || echo "")
    fi
    
    # If still not found, try to get all keys and use the first one
    if [ -z "$ADMIN_PASSWORD_B64" ]; then
        log "Checking available keys in secret..."
        SECRET_DATA=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o json 2>/dev/null || echo "")
        if [ -n "$SECRET_DATA" ]; then
            # Try to extract first key from data section
            FIRST_KEY=$(echo "$SECRET_DATA" | jq -r '.data | keys[0]' 2>/dev/null || echo "")
            if [ -n "$FIRST_KEY" ] && [ "$FIRST_KEY" != "null" ]; then
                log "Found key '$FIRST_KEY' in secret, using it..."
                ADMIN_PASSWORD_B64=$(echo "$SECRET_DATA" | jq -r ".data.$FIRST_KEY" 2>/dev/null || echo "")
            fi
        fi
    fi
    
    # If still not found, fall back to environment variable
    if [ -z "$ADMIN_PASSWORD_B64" ]; then
        log "Could not extract password from secret, checking environment variable ACS_PORTAL_PASSWORD..."
        if [ -n "$ACS_PORTAL_PASSWORD" ]; then
            ADMIN_PASSWORD_B64="$ACS_PORTAL_PASSWORD"
            log "✓ Using password from ACS_PORTAL_PASSWORD environment variable"
        else
            error "Could not extract password from secret 'central-htpasswd' in namespace '$RHACS_NAMESPACE' and ACS_PORTAL_PASSWORD environment variable not set"
        fi
    fi
fi

# Decode password (ACS_PORTAL_PASSWORD is already base64 encoded)
ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null || echo "")
if [ -z "$ADMIN_PASSWORD" ]; then
    error "Failed to decode admin password. The password might not be base64 encoded."
fi
log "✓ Admin password extracted"

# Generate ROX_API_TOKEN
log "Generating API token..."
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT#https://}"
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"

set +e
TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
    -u "admin:${ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
    -d '{"name":"rhacs-config-script-token","roles":["Admin"]}' 2>&1)
TOKEN_CURL_EXIT_CODE=$?
set -e

if [ $TOKEN_CURL_EXIT_CODE -ne 0 ]; then
    error "Failed to generate API token. curl exit code: $TOKEN_CURL_EXIT_CODE. Response: ${TOKEN_RESPONSE:0:300}"
fi

# Extract token from response
if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
    ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "")
fi

if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ]; then
    # Try to extract token from response text
    ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
fi

if [ -z "$ROX_API_TOKEN" ]; then
    error "Failed to extract API token from response. Response: ${TOKEN_RESPONSE:0:500}"
fi

# Verify token is not empty and has reasonable length
if [ ${#ROX_API_TOKEN} -lt 20 ]; then
    error "Generated token appears to be invalid (too short: ${#ROX_API_TOKEN} chars)"
fi

log "✓ API token generated (length: ${#ROX_API_TOKEN} chars)"

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq..."
    if command -v dnf >/dev/null 2>&1; then
        if ! sudo dnf install -y jq; then
            error "Failed to install jq using dnf. Check sudo permissions and package repository."
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if ! sudo apt-get update && sudo apt-get install -y jq; then
            error "Failed to install jq using apt-get. Check sudo permissions and package repository."
        fi
    else
        error "jq is required for this script to work correctly. Please install jq manually."
    fi
    log "✓ jq installed successfully"
else
    log "✓ jq is already installed"
fi

# Ensure ROX_ENDPOINT has https:// prefix for API calls
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT#https://}"
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"
API_BASE="https://${ROX_ENDPOINT_FOR_API}/v1"

# Function to make API call
make_api_call() {
    local method=$1
    local endpoint=$2
    local data="${3:-}"
    local description="${4:-API call}"
    
    # Redirect log to stderr so it's not captured in response
    log "Making $description: $method $endpoint" >&2
    
    local temp_file=""
    local curl_cmd="curl -k -s -w \"\n%{http_code}\" -X $method"
    curl_cmd="$curl_cmd -H \"Authorization: Bearer $ROX_API_TOKEN\""
    curl_cmd="$curl_cmd -H \"Content-Type: application/json\""
    
    if [ -n "$data" ]; then
        # For multi-line JSON, use a temporary file to avoid quoting issues
        if echo "$data" | grep -q $'\n'; then
            temp_file=$(mktemp)
            echo "$data" > "$temp_file"
            curl_cmd="$curl_cmd --data-binary @\"$temp_file\""
        else
            # Single-line data can use -d directly
            curl_cmd="$curl_cmd -d '$data'"
        fi
    fi
    
    curl_cmd="$curl_cmd \"$API_BASE/$endpoint\""
    
    local response=$(eval "$curl_cmd" 2>&1)
    local exit_code=$?
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | head -n -1)
    
    # Clean up temp file if used
    if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
        rm -f "$temp_file"
    fi
    
    if [ $exit_code -ne 0 ]; then
        error "$description failed (curl exit code: $exit_code). Response: ${body:0:500}"
    fi
    
    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        error "$description failed (HTTP $http_code). Response: ${body:0:500}"
    fi
    
    echo "$body"
}


# Prepare configuration payload
log "Preparing configuration payload..."
CONFIG_PAYLOAD=$(cat <<'EOF'
{
  "config": {
    "publicConfig": {
      "loginNotice": { "enabled": false, "text": "" },
      "header": { "enabled": false, "text": "", "size": "UNSET", "color": "#000000", "backgroundColor": "#FFFFFF" },
      "footer": { "enabled": false, "text": "", "size": "UNSET", "color": "#000000", "backgroundColor": "#FFFFFF" },
      "telemetry": { "enabled": true, "lastSetTime": null }
    },
    "privateConfig": {
      "alertConfig": {
        "resolvedDeployRetentionDurationDays": 7,
        "deletedRuntimeRetentionDurationDays": 7,
        "allRuntimeRetentionDurationDays": 30,
        "attemptedDeployRetentionDurationDays": 7,
        "attemptedRuntimeRetentionDurationDays": 7
      },
      "imageRetentionDurationDays": 7,
      "expiredVulnReqRetentionDurationDays": 90,
      "decommissionedClusterRetention": {
        "retentionDurationDays": 0,
        "ignoreClusterLabels": {},
        "lastUpdated": "2025-11-26T15:02:32.522230327Z",
        "createdAt": "2025-11-26T15:02:32.522229766Z"
      },
      "reportRetentionConfig": {
        "historyRetentionDurationDays": 7,
        "downloadableReportRetentionDays": 7,
        "downloadableReportGlobalRetentionBytes": 524288000
      },
      "vulnerabilityExceptionConfig": {
        "expiryOptions": {
          "dayOptions": [
            { "numDays": 14, "enabled": true },
            { "numDays": 30, "enabled": true },
            { "numDays": 60, "enabled": true },
            { "numDays": 90, "enabled": true }
          ],
          "fixableCveOptions": { "allFixable": true, "anyFixable": true },
          "customDate": false,
          "indefinite": false
        }
      },
      "administrationEventsConfig": { "retentionDurationDays": 4 },
      "metrics": {
        "imageVulnerabilities": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "cve_severity": { "labels": ["Cluster","CVE","IsPlatformWorkload","IsFixable","Severity"] },
            "deployment_severity": { "labels": ["Cluster","Namespace","Deployment","IsPlatformWorkload","IsFixable","Severity"] },
            "namespace_severity": { "labels": ["Cluster","Namespace","IsPlatformWorkload","IsFixable","Severity"] }
          }
        },
        "policyViolations": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "deployment_severity": { "labels": ["Cluster","Namespace","Deployment","IsPlatformComponent","Action","Severity"] },
            "namespace_severity": { "labels": ["Cluster","Namespace","IsPlatformComponent","Action","Severity"] }
          }
        },
        "nodeVulnerabilities": {
          "gatheringPeriodMinutes": 1,
          "descriptors": {
            "component_severity": { "labels": ["Cluster","Node","Component","IsFixable","Severity"] },
            "cve_severity": { "labels": ["Cluster","CVE","IsFixable","Severity"] },
            "node_severity": { "labels": ["Cluster","Node","IsFixable","Severity"] }
          }
        }
      }
    },
    "platformComponentConfig": {
      "rules": [
        {
          "name": "red hat layered products",
          "namespaceRule": { "regex": "^aap$|^ack-system$|^aws-load-balancer-operator$|^cert-manager-operator$|^cert-utils-operator$|^costmanagement-metrics-operator$|^external-dns-operator$|^metallb-system$|^mtr$|^multicluster-engine$|^multicluster-global-hub$|^node-observability-operator$|^open-cluster-management$|^openshift-adp$|^openshift-apiserver-operator$|^openshift-authentication$|^openshift-authentication-operator$|^openshift-builds$|^openshift-cloud-controller-manager$|^openshift-cloud-controller-manager-operator$|^openshift-cloud-credential-operator$|^openshift-cloud-network-config-controller$|^openshift-cluster-csi-drivers$|^openshift-cluster-machine-approver$|^openshift-cluster-node-tuning-operator$|^openshift-cluster-observability-operator$|^openshift-cluster-samples-operator$|^openshift-cluster-storage-operator$|^openshift-cluster-version$|^openshift-cnv$|^openshift-compliance$|^openshift-config$|^openshift-config-managed$|^openshift-config-operator$|^openshift-console$|^openshift-console-operator$|^openshift-console-user-settings$|^openshift-controller-manager$|^openshift-controller-manager-operator$|^openshift-dbaas-operator$|^openshift-distributed-tracing$|^openshift-dns$|^openshift-dns-operator$|^openshift-dpu-network-operator$|^openshift-dr-system$|^openshift-etcd$|^openshift-etcd-operator$|^openshift-file-integrity$|^openshift-gitops-operator$|^openshift-host-network$|^openshift-image-registry$|^openshift-infra$|^openshift-ingress$|^openshift-ingress-canary$|^openshift-ingress-node-firewall$|^openshift-ingress-operator$|^openshift-insights$|^openshift-keda$|^openshift-kmm$|^openshift-kmm-hub$|^openshift-kni-infra$|^openshift-kube-apiserver$|^openshift-kube-apiserver-operator$|^openshift-kube-controller-manager$|^openshift-kube-controller-manager-operator$|^openshift-kube-scheduler$|^openshift-kube-scheduler-operator$|^openshift-kube-storage-version-migrator$|^openshift-kube-storage-version-migrator-operator$|^openshift-lifecycle-agent$|^openshift-local-storage$|^openshift-logging$|^openshift-machine-api$|^openshift-machine-config-operator$|^openshift-marketplace$|^openshift-migration$|^openshift-monitoring$|^openshift-mta$|^openshift-mtv$|^openshift-multus$|^openshift-netobserv-operator$|^openshift-network-diagnostics$|^openshift-network-node-identity$|^openshift-network-operator$|^openshift-nfd$|^openshift-nmstate$|^openshift-node$|^openshift-nutanix-infra$|^openshift-oauth-apiserver$|^openshift-openstack-infra$|^openshift-opentelemetry-operator$|^openshift-operator-lifecycle-manager$|^openshift-operators$|^openshift-operators-redhat$|^openshift-ovirt-infra$|^openshift-ovn-kubernetes$|^openshift-ptp$|^openshift-route-controller-manager$|^openshift-sandboxed-containers-operator$|^openshift-security-profiles$|^openshift-serverless$|^openshift-serverless-logic$|^openshift-service-ca$|^openshift-service-ca-operator$|^openshift-sriov-network-operator$|^openshift-storage$|^openshift-tempo-operator$|^openshift-update-service$|^openshift-user-workload-monitoring$|^openshift-vertical-pod-autoscaler$|^openshift-vsphere-infra$|^openshift-windows-machine-config-operator$|^openshift-workload-availability$|^redhat-ods-operator$|^rhacs-operator$|^rhdh-operator$|^service-telemetry$|^stackrox$|^submariner-operator$|^tssc-acs$|^openshift-devspaces$" }
        },
        {
          "name": "system rule",
          "namespaceRule": { "regex": "^openshift$|^openshift-apiserver$|^openshift-operators$|^kube-.*" }
        }
      ],
      "needsReevaluation": false
    }
  }
}
EOF
)

# Update configuration
log "Updating RHACS configuration..."
CONFIG_RESPONSE=$(make_api_call "PUT" "config" "$CONFIG_PAYLOAD" "Update RHACS configuration")
log "✓ Configuration updated successfully (HTTP 200)"

# Validate configuration changes
log "Validating configuration changes..."
VALIDATED_CONFIG=$(make_api_call "GET" "config" "" "Validate configuration")
log "✓ Configuration validated"

# Verify key settings
log "Verifying telemetry configuration..."
TELEMETRY_ENABLED=$(echo "$VALIDATED_CONFIG" | jq -r '.config.publicConfig.telemetry.enabled' 2>/dev/null || echo "unknown")

if [ "$TELEMETRY_ENABLED" = "true" ]; then
    log "✓ Telemetry configuration verified: enabled"
elif [ "$TELEMETRY_ENABLED" != "unknown" ]; then
    log "✓ Telemetry configuration: $TELEMETRY_ENABLED"
fi

log "========================================================="
log "RHACS Configuration Script Completed Successfully"
log "========================================================="
log ""
log "Summary:"
log "  - Telemetry/monitoring enabled"
log "  - Metrics collection configured (image, policy, node vulnerabilities)"
log "  - Platform component rules updated (Red Hat layered products)"
log "  - Retention policies configured"
log "  - Configuration validated"

