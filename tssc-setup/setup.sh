#!/bin/bash

# Master script to install and deploy Red Hat Trusted Artifact Signer (RHTAS)
# This script orchestrates the installation of Keycloak, RHTAS Operator, and RHTAS components
# Usage: ./setup.sh [--skip-keycloak] [--skip-operator] [--skip-deploy]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[SETUP] ERROR:${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${BLUE}[SETUP]${NC} $1"
}

# Parse command line arguments
SKIP_KEYCLOAK=false
SKIP_OPERATOR=false
SKIP_DEPLOY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-keycloak)
            SKIP_KEYCLOAK=true
            shift
            ;;
        --skip-operator)
            SKIP_OPERATOR=true
            shift
            ;;
        --skip-deploy)
            SKIP_DEPLOY=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-keycloak    Skip Keycloak installation"
            echo "  --skip-operator    Skip RHTAS Operator installation"
            echo "  --skip-deploy      Skip RHTAS component deployment"
            echo "  --help, -h         Show this help message"
            echo ""
            echo "This script installs and deploys Red Hat Trusted Artifact Signer (RHTAS)"
            echo "in the following order:"
            echo "  1. Keycloak (RHSSO) installation"
            echo "  2. RHTAS Operator installation"
            echo "  3. RHTAS component deployment"
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

log "========================================================="
log "Red Hat Trusted Artifact Signer (RHTAS) Setup"
log "========================================================="
log ""

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
if ! oc whoami >/dev/null 2>&1; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

# Check if scripts exist
KEYCLOAK_SCRIPT="${SCRIPT_DIR}/01-keycloak.sh"
OPERATOR_SCRIPT="${SCRIPT_DIR}/02-operator.sh"
DEPLOY_SCRIPT="${SCRIPT_DIR}/03-deploy.sh"

if [ ! -f "$KEYCLOAK_SCRIPT" ]; then
    error "Keycloak script not found: $KEYCLOAK_SCRIPT"
fi
if [ ! -f "$OPERATOR_SCRIPT" ]; then
    error "Operator script not found: $OPERATOR_SCRIPT"
fi
if [ ! -f "$DEPLOY_SCRIPT" ]; then
    error "Deploy script not found: $DEPLOY_SCRIPT"
fi

log "✓ All required scripts found"
log ""

# Step 1: Install Keycloak
if [ "$SKIP_KEYCLOAK" = false ]; then
    log "========================================================="
    log "Step 1: Installing Keycloak (RHSSO)"
    log "========================================================="
    log ""
    
    if bash "$KEYCLOAK_SCRIPT"; then
        log "✓ Keycloak installation completed successfully"
    else
        error "Keycloak installation failed"
    fi
    log ""
else
    warning "Skipping Keycloak installation (--skip-keycloak)"
    log ""
fi

# Step 2: Install RHTAS Operator
if [ "$SKIP_OPERATOR" = false ]; then
    log "========================================================="
    log "Step 2: Installing RHTAS Operator"
    log "========================================================="
    log ""
    
    if bash "$OPERATOR_SCRIPT"; then
        log "✓ RHTAS Operator installation completed successfully"
    else
        error "RHTAS Operator installation failed"
    fi
    log ""
else
    warning "Skipping RHTAS Operator installation (--skip-operator)"
    log ""
fi

# Step 3: Deploy RHTAS Components
if [ "$SKIP_DEPLOY" = false ]; then
    log "========================================================="
    log "Step 3: Deploying RHTAS Components"
    log "========================================================="
    log ""
    
    if bash "$DEPLOY_SCRIPT"; then
        log "✓ RHTAS component deployment completed successfully"
    else
        error "RHTAS component deployment failed"
    fi
    log ""
else
    warning "Skipping RHTAS component deployment (--skip-deploy)"
    log ""
fi

log "========================================================="
log "RHTAS Setup Complete!"
log "========================================================="
log ""
log "All components have been installed and deployed successfully."
log ""

# Retrieve Keycloak credentials and URL
if [ "$SKIP_KEYCLOAK" = false ]; then
    log "Retrieving Keycloak access information..."
    KEYCLOAK_NAMESPACE="rhsso"
    KEYCLOAK_CR_NAME="rhsso-instance"
    
    # Determine the correct CRD name
    KEYCLOAK_CRD="keycloaks"
    if ! oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $KEYCLOAK_NAMESPACE >/dev/null 2>&1; then
        KEYCLOAK_CRD="keycloak"
    fi
    
    # Get Keycloak external URL
    KEYCLOAK_URL=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $KEYCLOAK_NAMESPACE -o jsonpath='{.status.externalURL}' 2>/dev/null || echo "")
    if [ -z "$KEYCLOAK_URL" ]; then
        KEYCLOAK_URL=$(oc get route keycloak -n $KEYCLOAK_NAMESPACE -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    fi
    
    # Get credential secret name
    KEYCLOAK_CREDENTIAL_SECRET=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n $KEYCLOAK_NAMESPACE -o jsonpath='{.status.credentialSecret}' 2>/dev/null || echo "")
    if [ -z "$KEYCLOAK_CREDENTIAL_SECRET" ]; then
        # Try common secret names
        for secret_name in "credential-rhsso-instance" "keycloak-credential" "rhsso-instance-credential"; do
            if oc get secret $secret_name -n $KEYCLOAK_NAMESPACE >/dev/null 2>&1; then
                KEYCLOAK_CREDENTIAL_SECRET=$secret_name
                break
            fi
        done
    fi
    
    # Get username and password from secret
    KEYCLOAK_ADMIN_USER=""
    KEYCLOAK_ADMIN_PASSWORD=""
    if [ -n "$KEYCLOAK_CREDENTIAL_SECRET" ]; then
        # Try multiple possible key names for username (check ADMIN_USERNAME first as it's most common for RHSSO)
        KEYCLOAK_ADMIN_USER=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $KEYCLOAK_NAMESPACE -o jsonpath='{.data.ADMIN_USERNAME}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [ -z "$KEYCLOAK_ADMIN_USER" ]; then
            KEYCLOAK_ADMIN_USER=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $KEYCLOAK_NAMESPACE -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        fi
        if [ -z "$KEYCLOAK_ADMIN_USER" ]; then
            KEYCLOAK_ADMIN_USER=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $KEYCLOAK_NAMESPACE -o jsonpath='{.data.adminUsername}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        fi
        
        # Try multiple possible key names for password (check ADMIN_PASSWORD first as it's most common for RHSSO)
        KEYCLOAK_ADMIN_PASSWORD=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $KEYCLOAK_NAMESPACE -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
            KEYCLOAK_ADMIN_PASSWORD=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $KEYCLOAK_NAMESPACE -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        fi
        if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
            KEYCLOAK_ADMIN_PASSWORD=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $KEYCLOAK_NAMESPACE -o jsonpath='{.data.adminPassword}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        fi
        
        # If still not found, try to get all keys and use jq if available
        if [ -z "$KEYCLOAK_ADMIN_USER" ] || [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
            if command -v jq >/dev/null 2>&1; then
                SECRET_DATA=$(oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $KEYCLOAK_NAMESPACE -o json 2>/dev/null || echo "")
                if [ -n "$SECRET_DATA" ]; then
                    # Get all keys in the secret
                    SECRET_KEYS=$(echo "$SECRET_DATA" | jq -r '.data | keys[]' 2>/dev/null || echo "")
                    # Try to find username-like key
                    if [ -z "$KEYCLOAK_ADMIN_USER" ]; then
                        for key in $SECRET_KEYS; do
                            if echo "$key" | grep -qi "user\|admin"; then
                                KEYCLOAK_ADMIN_USER=$(echo "$SECRET_DATA" | jq -r ".data.$key" 2>/dev/null | base64 -d 2>/dev/null || echo "")
                                if [ -n "$KEYCLOAK_ADMIN_USER" ]; then
                                    break
                                fi
                            fi
                        done
                    fi
                    # Try to find password-like key
                    if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
                        for key in $SECRET_KEYS; do
                            if echo "$key" | grep -qi "pass\|pwd"; then
                                KEYCLOAK_ADMIN_PASSWORD=$(echo "$SECRET_DATA" | jq -r ".data.$key" 2>/dev/null | base64 -d 2>/dev/null || echo "")
                                if [ -n "$KEYCLOAK_ADMIN_PASSWORD" ]; then
                                    break
                                fi
                            fi
                        done
                    fi
                fi
            fi
        fi
    fi
fi

log "To verify the installation:"
log "  oc get pods -n rhsso"
log "  oc get pods -n trusted-artifact-signer"
log "  oc get securesigns -n trusted-artifact-signer"
log ""
log "To get cosign configuration URLs, run:"
log "  bash ${DEPLOY_SCRIPT}"
log ""

# Display Keycloak Admin Access Information at the end
if [ "$SKIP_KEYCLOAK" = false ]; then
    log ""
    log "========================================================="
    log "Keycloak Admin Access Information"
    log "========================================================="
    if [ -n "$KEYCLOAK_URL" ]; then
        log "Keycloak URL: $KEYCLOAK_URL"
    else
        warning "Keycloak URL not found"
    fi
    if [ -n "$KEYCLOAK_ADMIN_USER" ] && [ -n "$KEYCLOAK_ADMIN_PASSWORD" ]; then
        log "Admin Username: $KEYCLOAK_ADMIN_USER"
        log "Admin Password: $KEYCLOAK_ADMIN_PASSWORD"
    elif [ -n "$KEYCLOAK_CREDENTIAL_SECRET" ]; then
        log "Credentials stored in secret: $KEYCLOAK_CREDENTIAL_SECRET"
        log "  First, check what keys are available in the secret:"
        log "    oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $KEYCLOAK_NAMESPACE -o json | jq '.data | keys'"
        log "  Then try retrieving with the actual key names found above:"
        log "    oc get secret $KEYCLOAK_CREDENTIAL_SECRET -n $KEYCLOAK_NAMESPACE -o jsonpath='{.data.<KEY_NAME>}' | base64 -d"
        log "  Common key names to try:"
        log "    username, ADMIN_USERNAME, adminUsername"
        log "    password, ADMIN_PASSWORD, adminPassword"
    else
        warning "Keycloak credentials not found"
    fi
    log "========================================================="
    log ""
fi

