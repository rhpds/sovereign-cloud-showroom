#!/bin/bash
# Script to clean up RHTAS operator subscriptions and CSVs from all namespaces
# This is useful when subscriptions have been created in incorrect namespaces

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[CLEANUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[CLEANUP]${NC} $1"
}

error() {
    echo -e "${RED}[CLEANUP] ERROR:${NC} $1" >&2
    exit 1
}

# Check if oc is available
if ! oc whoami >/dev/null 2>&1; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi

log "========================================================="
log "RHTAS Subscription and CSV Cleanup"
log "========================================================="
log ""

# Find all subscriptions named trusted-artifact-signer
log "Finding all RHTAS subscriptions..."
SUBSCRIPTIONS=$(oc get subscription -A -o jsonpath='{range .items[?(@.metadata.name=="trusted-artifact-signer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

if [ -z "$SUBSCRIPTIONS" ]; then
    log "No RHTAS subscriptions found"
else
    log "Found RHTAS subscriptions in the following namespaces:"
    echo "$SUBSCRIPTIONS" | while read -r ns name; do
        if [ "$ns" = "openshift-operators" ]; then
            log "  ✓ $ns/$name (correct namespace)"
        else
            warning "  ✗ $ns/$name (incorrect namespace)"
        fi
    done
    log ""
    
    # Ask for confirmation
    read -p "Do you want to delete subscriptions in incorrect namespaces? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "$SUBSCRIPTIONS" | while read -r ns name; do
            if [ "$ns" != "openshift-operators" ]; then
                log "Deleting subscription $name from namespace $ns..."
                oc delete subscription $name -n $ns --ignore-not-found=true 2>/dev/null || warning "Failed to delete subscription in $ns"
            fi
        done
        log "✓ Cleanup of incorrect subscriptions completed"
    else
        log "Skipping subscription deletion"
    fi
fi

log ""

# Find all CSVs for rhtas-operator
log "Finding all RHTAS CSVs..."
CSVS=$(oc get csv -A -o jsonpath='{range .items[?(@.spec.displayName=="Trusted Artifact Signer Operator")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

if [ -z "$CSVS" ]; then
    log "No RHTAS CSVs found"
else
    log "Found RHTAS CSVs in the following namespaces:"
    echo "$CSVS" | while read -r ns name; do
        if [ "$ns" = "openshift-operators" ]; then
            log "  ✓ $ns/$name (correct namespace)"
        else
            warning "  ✗ $ns/$name (incorrect namespace)"
        fi
    done
    log ""
    
    # Ask for confirmation
    read -p "Do you want to delete CSVs in incorrect namespaces? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "$CSVS" | while read -r ns name; do
            if [ "$ns" != "openshift-operators" ]; then
                log "Deleting CSV $name from namespace $ns..."
                oc delete csv $name -n $ns --ignore-not-found=true 2>/dev/null || warning "Failed to delete CSV in $ns"
            fi
        done
        log "✓ Cleanup of incorrect CSVs completed"
    else
        log "Skipping CSV deletion"
    fi
fi

log ""
log "========================================================="
log "Cleanup Summary"
log "========================================================="
log ""
log "Remaining subscriptions:"
oc get subscription -A | grep trusted-artifact-signer || log "  None"
log ""
log "Remaining CSVs:"
oc get csv -A | grep rhtas-operator || log "  None"
log ""
log "Cleanup script completed"
log ""
