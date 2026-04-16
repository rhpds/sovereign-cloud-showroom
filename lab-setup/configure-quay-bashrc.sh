#!/bin/bash
# Writes QUAY_USER and QUAY_URL to ~/.bashrc for module-03 (podman login https://$QUAY_URL -u $QUAY_USER).
# Idempotent: removes prior QUAY_* export lines before appending. Safe to re-run after Quay becomes ready.

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[QUAY-BASHRC]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[QUAY-BASHRC]${NC} $1"
}

context_exists() {
    oc config get-contexts -o name 2>/dev/null | sed 's|^context/||' | grep -qx "$1"
}

main() {
    local ctx=local-cluster
    if ! context_exists "$ctx"; then
        warning "Skipping QUAY_* in ~/.bashrc: context '$ctx' not in kubeconfig"
        return 0
    fi
    if ! oc --context="$ctx" whoami &>/dev/null; then
        warning "Skipping QUAY_* in ~/.bashrc: not authorized on $ctx"
        return 0
    fi

    local max_wait=120
    local waited=0
    local host=""
    while [ "$waited" -lt "$max_wait" ]; do
        host=$(oc --context="$ctx" get route quay-quay -n quay -o jsonpath='{.spec.host}' 2>/dev/null || true)
        if [ -n "$host" ]; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    if [ -z "$host" ]; then
        warning "Route quay-quay not found in namespace quay on $ctx — QUAY_URL not added to ~/.bashrc (re-run this script when Quay is ready)"
        return 0
    fi

    local quay_url="$host"
    quay_url="${quay_url#https://}"
    quay_url="${quay_url#http://}"

    touch "${HOME}/.bashrc" 2>/dev/null || true
    if [ -f "${HOME}/.bashrc" ]; then
        sed -i '/^export QUAY_USER=/d' "${HOME}/.bashrc"
        sed -i '/^export QUAY_URL=/d' "${HOME}/.bashrc"
    fi
    echo 'export QUAY_USER=quayadmin' >>"${HOME}/.bashrc"
    echo "export QUAY_URL=\"${quay_url}\"" >>"${HOME}/.bashrc"
    export QUAY_USER=quayadmin
    export QUAY_URL="${quay_url}"
    log "✓ QUAY_USER and QUAY_URL written to ~/.bashrc (QUAY_URL=${quay_url})"
    return 0
}

main "$@"
