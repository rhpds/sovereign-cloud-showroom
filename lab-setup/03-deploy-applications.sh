#!/bin/bash
# Application Deployment Script
# Deploys applications to OpenShift cluster and runs security scans

# Don't exit on error - just deploy and continue
set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[APP-DEPLOY]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[APP-DEPLOY]${NC} $1"
}

error() {
    echo -e "${RED}[APP-DEPLOY] ERROR:${NC} $1" >&2
    echo -e "${RED}[APP-DEPLOY] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# No error trap - just continue on errors

# Set up script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
DEMO_LABEL="demo=roadshow"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"
log "Prerequisites validated successfully"

# Clone demo-applications repository
log "Cloning demo-applications repository..."
DEMO_APPS_REPO_DIR=""
if [ -d "$HOME/demo-applications" ]; then
    log "demo-applications repository already exists at $HOME/demo-applications"
    DEMO_APPS_REPO_DIR="$HOME/demo-applications"
elif [ -d "$PROJECT_ROOT/../demo-applications" ]; then
    log "demo-applications repository found at $PROJECT_ROOT/../demo-applications"
    DEMO_APPS_REPO_DIR="$PROJECT_ROOT/../demo-applications"
else
    if git clone https://github.com/mfosterrox/demo-applications.git "$HOME/demo-applications"; then
        log "✓ Cloned demo-applications repository"
        DEMO_APPS_REPO_DIR="$HOME/demo-applications"
    else
        error "Failed to clone demo-applications repository. Check network connectivity and repository access."
    fi
fi

# Set TUTORIAL_HOME environment variable to point to demo-applications
log "Setting TUTORIAL_HOME environment variable..."
TUTORIAL_HOME="$DEMO_APPS_REPO_DIR"
if [ ! -d "$TUTORIAL_HOME" ]; then
    error "TUTORIAL_HOME directory does not exist: $TUTORIAL_HOME"
fi
sed -i '/^export TUTORIAL_HOME=/d' ~/.bashrc
echo "export TUTORIAL_HOME=\"$TUTORIAL_HOME\"" >> ~/.bashrc
export TUTORIAL_HOME="$TUTORIAL_HOME"
log "✓ TUTORIAL_HOME set to: $TUTORIAL_HOME"

# Function to deploy applications to a cluster
deploy_to_cluster() {
    local CLUSTER_NAME="$1"
    local CLUSTER_CONTEXT="$2"
    
    log ""
    log "========================================================="
    log "Deploying applications to $CLUSTER_NAME cluster"
    log "========================================================="
    
    # Switch to cluster context
    log "Switching to $CLUSTER_NAME context..."
    if ! oc config use-context "$CLUSTER_CONTEXT" >/dev/null 2>&1; then
        warning "Failed to switch to $CLUSTER_NAME context. Skipping deployment to this cluster."
        return 1
    fi
    log "✓ Switched to $CLUSTER_NAME context"
    
    # Verify connection
    if ! oc whoami >/dev/null 2>&1; then
        warning "Not connected to $CLUSTER_NAME cluster. Skipping deployment."
        return 1
    fi
    log "✓ Connected to $CLUSTER_NAME cluster as: $(oc whoami)"
    
    # Deploy k8s-deployment-manifests (all applications)
    if [ -d "$TUTORIAL_HOME/k8s-deployment-manifests" ]; then
        log "Deploying k8s-deployment-manifests to $CLUSTER_NAME..."
        oc apply -f "$TUTORIAL_HOME/k8s-deployment-manifests/" --recursive || warning "Some resources in k8s-deployment-manifests may have failed to apply to $CLUSTER_NAME"
        log "✓ k8s-deployment-manifests deployment attempted on $CLUSTER_NAME"
    else
        warning "k8s-deployment-manifests directory not found at: $TUTORIAL_HOME/k8s-deployment-manifests"
    fi
    
    log "✓ Deployment to $CLUSTER_NAME completed"
}

# Deploy applications
log "Deploying applications from $TUTORIAL_HOME..."

# Store current context
CURRENT_CONTEXT=$(oc config current-context 2>/dev/null || echo "")

# Ensure we're in local-cluster context
log "Ensuring we're in local-cluster context..."
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

# Deploy to local-cluster only
deploy_to_cluster "local-cluster" "local-cluster"

# Restore original context if it was set and different
if [ -n "$CURRENT_CONTEXT" ] && [ "$CURRENT_CONTEXT" != "local-cluster" ]; then
    log ""
    log "Restoring original context: $CURRENT_CONTEXT"
    oc config use-context "$CURRENT_CONTEXT" >/dev/null 2>&1 || true
fi

# Deployment complete - applications will start in the background
log ""
log "========================================================="
log "Application deployment completed!"
log "========================================================="
log "Applications have been deployed to:"
log "  - local-cluster"
log ""
log "Applications will start in the background."
log "You can check their status with:"
log "  oc get pods -A (on current cluster)"
log "  oc config use-context local-cluster && oc get pods -A (for local-cluster)"
log ""