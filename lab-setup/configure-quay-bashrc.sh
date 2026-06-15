#!/bin/bash
# Writes QUAY_USER and QUAY_URL to ~/.bashrc for module-03 (podman login https://$QUAY_URL -u $QUAY_USER).
# Idempotent: removes prior QUAY_* export lines before appending. Safe to re-run after Quay becomes ready.
#
# Quay's Route often appears well after manifests apply; increase wait with QUAY_BASHRC_MAX_WAIT (seconds).
# Override cluster context with QUAY_OC_CONTEXT if kubeconfig has no local-cluster.
# Set QUAY_BASHRC_QUIET=1 to suppress stdout (e.g. when setup.sh runs this after parallel install).

set -uo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    [[ -n "${QUAY_BASHRC_QUIET:-}" ]] && return 0
    echo -e "${GREEN}[QUAY-BASHRC]${NC} $1"
}

warning() {
    [[ -n "${QUAY_BASHRC_QUIET:-}" ]] && return 0
    echo -e "${YELLOW}[QUAY-BASHRC]${NC} $1"
}

context_exists() {
    oc config get-contexts -o name 2>/dev/null | sed 's|^context/||' | grep -qx "$1"
}

# Prefer QUAY_OC_CONTEXT, then local-cluster, then any context that can talk to the cluster.
resolve_context() {
    local preferred="${QUAY_OC_CONTEXT:-local-cluster}"
    if context_exists "$preferred" && oc --context="$preferred" whoami &>/dev/null; then
        echo "$preferred"
        return 0
    fi
    local cur
    cur=$(oc config current-context 2>/dev/null || true)
    if [ -n "$cur" ] && oc --context="$cur" whoami &>/dev/null; then
        warning "Using OpenShift context '$cur' (preferred '${preferred}' missing or not logged in)"
        echo "$cur"
        return 0
    fi
    echo ""
    return 1
}

# Try common Quay operator route names, then any route in namespace quay.
discover_quay_host() {
    local ctx="$1"
    local name host
    for name in quay-quay quay registry; do
        host=$(oc --context="$ctx" get route "$name" -n quay -o jsonpath='{.spec.host}' 2>/dev/null || true)
        if [ -n "$host" ]; then
            echo "$host"
            return 0
        fi
    done
    # Prefer registry route by name (items[0] can be quay-quay-builder depending on API order)
    host=$(oc --context="$ctx" get routes -n quay -o jsonpath='{.items[?(@.metadata.name=="quay-quay")].spec.host}' 2>/dev/null || true)
    if [ -n "$host" ]; then
        echo "$host"
        return 0
    fi
    return 1
}

main() {
    local ctx
    ctx=$(resolve_context) || {
        warning "Skipping QUAY_* in ~/.bashrc: no usable OpenShift context (log in with oc login or set QUAY_OC_CONTEXT)"
        return 0
    }

    local max_wait="${QUAY_BASHRC_MAX_WAIT:-600}"
    local interval="${QUAY_BASHRC_POLL_INTERVAL:-10}"
    local waited=0
    local host=""

    log "Waiting up to ${max_wait}s for a Quay Route in namespace quay (context: $ctx)..."
    while [ "$waited" -lt "$max_wait" ]; do
        if host=$(discover_quay_host "$ctx"); then
            break
        fi
        sleep "$interval"
        waited=$((waited + interval))
    done

    if [ -z "$host" ]; then
        warning "No Quay route found in namespace quay on context $ctx — QUAY_URL not added to ~/.bashrc"
        warning "When Quay is ready, run: bash \"\${PROJECT_ROOT:-.}/lab-setup/configure-quay-bashrc.sh\""
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
