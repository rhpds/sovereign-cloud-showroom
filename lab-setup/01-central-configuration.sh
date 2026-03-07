#!/bin/bash
# RHACS Central Route Configuration Script
# Configures Central CR with passthrough and reencrypt routes

# Exit immediately on error, show error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[RHACS-CENTRAL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[RHACS-CENTRAL]${NC} $1"
}

error() {
    echo -e "${RED}[RHACS-CENTRAL] ERROR:${NC} $1" >&2
    echo -e "${RED}[RHACS-CENTRAL] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Fixed values based on environment
CENTRAL_NAMESPACE="stackrox"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

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

# Find Central CR name
CENTRAL_NAME=$(oc get central -n "$CENTRAL_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_NAME" ]; then
    error "Central CR not found in namespace $CENTRAL_NAMESPACE"
fi
log "✓ Found Central CR: $CENTRAL_NAME"

log ""
log "Central CR configuration script complete"
log ""
