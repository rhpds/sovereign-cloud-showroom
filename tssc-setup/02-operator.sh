#!/bin/bash

# Script to install Red Hat Trusted Artifact Signer (RHTAS) with Red Hat SSO (Keycloak) as OIDC provider on OpenShift
# Assumes oc is installed and user is logged in as cluster-admin
# Assumes Keycloak is installed (RH SSO/rhsso, or Red Hat build of Keycloak rhbk-operator / namespace keycloak, etc.)
# Usage: ./08-install-trusted-artifact-signer.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keycloak / RHTAS target the hub cluster (same as lab / ai-setup). Parallel drivers may leave another context selected.
KUBE_CONTEXT="${KUBE_CONTEXT:-local-cluster}"
oc config use-context "$KUBE_CONTEXT" &>/dev/null || true

# True if namespace hosts a Keycloak instance signal (CR, workload, or route) — not "namespace exists".
keycloak_namespace_has_instance_signals() {
    local ns=$1 rt
    [ -z "$ns" ] && return 1
    oc get namespace "$ns" >/dev/null 2>&1 || return 1
    if oc get keycloaks.k8s.keycloak.org -n "$ns" --no-headers 2>/dev/null | grep -q .; then
        return 0
    fi
    if oc get keycloak.k8s.keycloak.org -n "$ns" --no-headers 2>/dev/null | grep -q .; then
        return 0
    fi
    if oc get keycloakrealmimports.k8s.keycloak.org -n "$ns" --no-headers 2>/dev/null | grep -q .; then
        return 0
    fi
    if oc get keycloaks.keycloak.org -n "$ns" --no-headers 2>/dev/null | grep -q .; then
        return 0
    fi
    if oc get keycloak.keycloak.org -n "$ns" --no-headers 2>/dev/null | grep -q .; then
        return 0
    fi
    if oc get deployment -n "$ns" -l app.kubernetes.io/name=keycloak --no-headers 2>/dev/null | grep -q .; then
        return 0
    fi
    if oc get statefulset keycloak -n "$ns" &>/dev/null; then
        return 0
    fi
    if oc get pods -n "$ns" --no-headers 2>/dev/null | grep -qiE 'keycloak|rhbk'; then
        return 0
    fi
    for rt in keycloak keycloak-rhsso rhbk-keycloak sso; do
        oc get route "$rt" -n "$ns" &>/dev/null && return 0
    done
    return 1
}

# Resolve Keycloak namespace from CRs / workloads / routes — not OLM Subscriptions; never prefer empty rhsso over keycloak.
discover_keycloak_namespace() {
    local ns _csv_line _routes_out line _r_ns _r_name
    if [ -n "${KEYCLOAK_NAMESPACE_OVERRIDE:-}" ] && oc get namespace "${KEYCLOAK_NAMESPACE_OVERRIDE}" >/dev/null 2>&1; then
        echo "${KEYCLOAK_NAMESPACE_OVERRIDE}"
        return 0
    fi
    if [ -n "${KEYCLOAK_NAMESPACE:-}" ] && oc get namespace "${KEYCLOAK_NAMESPACE}" >/dev/null 2>&1; then
        echo "${KEYCLOAK_NAMESPACE}"
        return 0
    fi

    # Prefer 'keycloak' before 'rhsso': labs often have an empty rhsso NS while RHBK lives in keycloak.
    for ns in keycloak rhsso; do
        if keycloak_namespace_has_instance_signals "$ns"; then
            echo "$ns"
            return 0
        fi
    done

    ns=$(oc get keycloaks.k8s.keycloak.org -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    [ -n "$ns" ] && echo "$ns" && return 0
    ns=$(oc get keycloak.k8s.keycloak.org -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    [ -n "$ns" ] && echo "$ns" && return 0
    ns=$(oc get keycloaks.keycloak.org -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    [ -n "$ns" ] && echo "$ns" && return 0

    ns=$(oc get deployment -A -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    [ -n "$ns" ] && echo "$ns" && return 0
    ns=$(oc get pods -A -l app.kubernetes.io/name=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    [ -n "$ns" ] && echo "$ns" && return 0

    # Operator CSV in the instance namespace only (not openshift-operators).
    for ns in keycloak rhsso; do
        oc get namespace "$ns" >/dev/null 2>&1 || continue
        if oc get csv -n "$ns" --no-headers 2>/dev/null | grep -qiE 'keycloak|rhbk'; then
            echo "$ns"
            return 0
        fi
    done

    _routes_out=$(oc get routes -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        _r_ns="${line%% *}"
        _r_name="${line#* }"
        case "$_r_name" in keycloak-rhsso|keycloak|rhbk-keycloak|sso)
            echo "$_r_ns"
            return 0
            ;;
        esac
    done <<< "$_routes_out"

    if oc get namespace keycloak >/dev/null 2>&1; then
        echo "keycloak"
        return 0
    fi
    if oc get namespace rhsso >/dev/null 2>&1; then
        echo "rhsso"
        return 0
    fi
    return 1
}

# RHBK / Keycloak Quarkus: https://HOST/realms/REALM — legacy RH-SSO: https://HOST/auth/realms/REALM
discover_keycloak_oidc_issuer_url() {
    local host=$1
    local realm=${2:-openshift}
    local base="https://${host}"
    local disco_mod="${base}/realms/${realm}/.well-known/openid-configuration"
    local disco_legacy="${base}/auth/realms/${realm}/.well-known/openid-configuration"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --connect-timeout 5 --max-time 15 "$disco_mod" 2>/dev/null | grep -q '"issuer"'; then
            echo "${base}/realms/${realm}"
            return 0
        fi
        if curl -fsS --connect-timeout 5 --max-time 15 "$disco_legacy" 2>/dev/null | grep -q '"issuer"'; then
            echo "${base}/auth/realms/${realm}"
            return 0
        fi
    fi
    if oc get keycloaks.k8s.keycloak.org -A --no-headers 2>/dev/null | grep -q .; then
        echo "${base}/realms/${realm}"
        return 0
    fi
    if oc get keycloak.k8s.keycloak.org -A --no-headers 2>/dev/null | grep -q .; then
        echo "${base}/realms/${realm}"
        return 0
    fi
    echo "${base}/auth/realms/${realm}"
    return 0
}

# --- Keycloak CR readiness: legacy keycloak.org vs Red Hat build (k8s.keycloak.org) ---
_kc_condition_true() {
    local res=$1 ns=$2 ctype=$3
    local st
    st=$(oc get "$res" -n "$ns" -o jsonpath="{.status.conditions[?(@.type==\"$ctype\")].status}" 2>/dev/null || true)
    [ "$st" = "True" ]
}

# Realm: RHBK uses conditions (Ready/Done) and/or phase Ready; RH-SSO uses .status.ready and phase reconciled.
keycloakrealm_is_reconciled() {
    local ns=$1 name=$2
    local ready_stat phase phase_lc
    if oc get "keycloakrealms.k8s.keycloak.org/$name" -n "$ns" &>/dev/null; then
        _kc_condition_true "keycloakrealms.k8s.keycloak.org/$name" "$ns" "Ready" && return 0
        _kc_condition_true "keycloakrealms.k8s.keycloak.org/$name" "$ns" "Done" && return 0
        phase=$(oc get "keycloakrealms.k8s.keycloak.org/$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        phase_lc=$(echo "$phase" | tr '[:upper:]' '[:lower:]')
        case "$phase_lc" in ready|done|reconciled) return 0 ;; esac
        return 1
    fi
    if oc get "keycloakrealms.keycloak.org/$name" -n "$ns" &>/dev/null; then
        ready_stat=$(oc get "keycloakrealms.keycloak.org/$name" -n "$ns" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        phase_lc=$(echo "$(oc get "keycloakrealms.keycloak.org/$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" | tr '[:upper:]' '[:lower:]')
        [ "$ready_stat" = "true" ] && return 0
        [ "$phase_lc" = "reconciled" ] && return 0
        return 1
    fi
    if oc get "keycloakrealm/$name" -n "$ns" &>/dev/null; then
        _kc_condition_true "keycloakrealm/$name" "$ns" "Ready" && return 0
        _kc_condition_true "keycloakrealm/$name" "$ns" "Done" && return 0
        ready_stat=$(oc get "keycloakrealm/$name" -n "$ns" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        phase_lc=$(echo "$(oc get "keycloakrealm/$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" | tr '[:upper:]' '[:lower:]')
        [ "$ready_stat" = "true" ] && return 0
        [ "$phase_lc" = "reconciled" ] && return 0
        case "$phase_lc" in ready|done) return 0 ;; esac
    fi
    return 1
}

keycloakrealm_cr_exists() {
    local ns=$1 name=$2
    oc get "keycloakrealms.k8s.keycloak.org/$name" -n "$ns" &>/dev/null && return 0
    oc get "keycloakrealms.keycloak.org/$name" -n "$ns" &>/dev/null && return 0
    oc get "keycloakrealm/$name" -n "$ns" &>/dev/null && return 0
    return 1
}

keycloakrealm_status_hint() {
    local ns=$1 name=$2
    if oc get "keycloakrealms.k8s.keycloak.org/$name" -n "$ns" &>/dev/null; then
        oc get "keycloakrealms.k8s.keycloak.org/$name" -n "$ns" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null | head -3 || true
        oc get "keycloakrealms.k8s.keycloak.org/$name" -n "$ns" -o jsonpath='phase={.status.phase}{"\n"}' 2>/dev/null || true
    elif oc get "keycloakrealms.keycloak.org/$name" -n "$ns" &>/dev/null; then
        oc get "keycloakrealms.keycloak.org/$name" -n "$ns" -o jsonpath='ready={.status.ready} phase={.status.phase}{"\n"}' 2>/dev/null || true
    else
        oc get "keycloakrealm/$name" -n "$ns" -o yaml 2>/dev/null | grep -A 12 '^status:' | head -14 || true
    fi
}

keycloakclient_is_reconciled() {
    local ns=$1 name=$2
    local ready_stat phase_lc
    if oc get "keycloakclients.k8s.keycloak.org/$name" -n "$ns" &>/dev/null; then
        _kc_condition_true "keycloakclients.k8s.keycloak.org/$name" "$ns" "Ready" && return 0
        _kc_condition_true "keycloakclients.k8s.keycloak.org/$name" "$ns" "Done" && return 0
        phase_lc=$(echo "$(oc get "keycloakclients.k8s.keycloak.org/$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" | tr '[:upper:]' '[:lower:]')
        case "$phase_lc" in ready|done|reconciled) return 0 ;; esac
        return 1
    fi
    if oc get "keycloakclients.keycloak.org/$name" -n "$ns" &>/dev/null; then
        ready_stat=$(oc get "keycloakclients.keycloak.org/$name" -n "$ns" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        phase_lc=$(echo "$(oc get "keycloakclients.keycloak.org/$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" | tr '[:upper:]' '[:lower:]')
        [ "$ready_stat" = "true" ] && return 0
        [ "$phase_lc" = "reconciled" ] && return 0
        return 1
    fi
    if oc get "keycloakclient/$name" -n "$ns" &>/dev/null; then
        _kc_condition_true "keycloakclient/$name" "$ns" "Ready" && return 0
        ready_stat=$(oc get "keycloakclient/$name" -n "$ns" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
        phase_lc=$(echo "$(oc get "keycloakclient/$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" | tr '[:upper:]' '[:lower:]')
        [ "$ready_stat" = "true" ] && return 0
        [ "$phase_lc" = "reconciled" ] && return 0
        case "$phase_lc" in ready|done) return 0 ;; esac
    fi
    return 1
}

keycloakclient_cr_exists() {
    local ns=$1 name=$2
    oc get "keycloakclients.k8s.keycloak.org/$name" -n "$ns" &>/dev/null && return 0
    oc get "keycloakclients.keycloak.org/$name" -n "$ns" &>/dev/null && return 0
    oc get "keycloakclient/$name" -n "$ns" &>/dev/null && return 0
    return 1
}

keycloakuser_is_reconciled() {
    local ns=$1 name=$2
    local phase_lc
    if oc get "keycloakusers.k8s.keycloak.org/$name" -n "$ns" &>/dev/null; then
        _kc_condition_true "keycloakusers.k8s.keycloak.org/$name" "$ns" "Ready" && return 0
        _kc_condition_true "keycloakusers.k8s.keycloak.org/$name" "$ns" "Done" && return 0
        phase_lc=$(echo "$(oc get "keycloakusers.k8s.keycloak.org/$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" | tr '[:upper:]' '[:lower:]')
        case "$phase_lc" in reconciled|ready|done) return 0 ;; esac
        return 1
    fi
    if oc get "keycloakusers.keycloak.org/$name" -n "$ns" &>/dev/null; then
        phase_lc=$(echo "$(oc get "keycloakusers.keycloak.org/$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" | tr '[:upper:]' '[:lower:]')
        [ "$phase_lc" = "reconciled" ] && return 0
        return 1
    fi
    if oc get "keycloakuser/$name" -n "$ns" &>/dev/null; then
        _kc_condition_true "keycloakuser/$name" "$ns" "Ready" && return 0
        phase_lc=$(echo "$(oc get "keycloakuser/$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" | tr '[:upper:]' '[:lower:]')
        [ "$phase_lc" = "reconciled" ] && return 0
        case "$phase_lc" in ready|done) return 0 ;; esac
    fi
    return 1
}

keycloakuser_cr_exists() {
    local ns=$1 name=$2
    oc get "keycloakusers.k8s.keycloak.org/$name" -n "$ns" &>/dev/null && return 0
    oc get "keycloakusers.keycloak.org/$name" -n "$ns" &>/dev/null && return 0
    oc get "keycloakuser/$name" -n "$ns" &>/dev/null && return 0
    return 1
}

keycloakclient_status_hint() {
    local ns=$1 name=$2
    if oc get "keycloakclients.k8s.keycloak.org/$name" -n "$ns" &>/dev/null; then
        oc get "keycloakclients.k8s.keycloak.org/$name" -n "$ns" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null | head -5 || true
        oc get "keycloakclients.k8s.keycloak.org/$name" -n "$ns" -o jsonpath='phase={.status.phase}{"\n"}' 2>/dev/null || true
    elif oc get "keycloakclients.keycloak.org/$name" -n "$ns" &>/dev/null; then
        oc get "keycloakclients.keycloak.org/$name" -n "$ns" -o jsonpath='ready={.status.ready} phase={.status.phase}{"\n"}' 2>/dev/null || true
    else
        oc get "keycloakclient/$name" -n "$ns" -o yaml 2>/dev/null | grep -A 14 '^status:' | head -16 || true
    fi
}

keycloakuser_status_hint() {
    local ns=$1 name=$2
    if oc get "keycloakusers.k8s.keycloak.org/$name" -n "$ns" &>/dev/null; then
        oc get "keycloakusers.k8s.keycloak.org/$name" -n "$ns" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>/dev/null | head -5 || true
    elif oc get "keycloakusers.keycloak.org/$name" -n "$ns" &>/dev/null; then
        oc get "keycloakusers.keycloak.org/$name" -n "$ns" -o jsonpath='phase={.status.phase}{"\n"}' 2>/dev/null || true
    else
        oc get "keycloakuser/$name" -n "$ns" -o yaml 2>/dev/null | grep -A 14 '^status:' | head -16 || true
    fi
}

# Block until reconciled; exit 1 on timeout (no warn-and-continue).
wait_keycloak_realm_reconciled_or_exit() {
    local ns=$1 name=$2
    local max="${MAX_WAIT_KC_REALM_CLIENT}"
    local w=0
    echo "Waiting for KeycloakRealm '${name}' to reconcile (required; max ${max}s)..."
    while [ "$w" -lt "$max" ]; do
        if keycloakrealm_is_reconciled "$ns" "$name"; then
            echo "✓ Realm '${name}' is reconciled"
            return 0
        fi
        sleep 5
        w=$((w + 5))
        if [ $((w % 10)) -eq 0 ] && [ "$w" -gt 0 ]; then
            echo "  Still waiting for realm... (${w}s/${max}s) — status:"
            keycloakrealm_status_hint "$ns" "$name" | sed 's/^/    | /' || true
        fi
    done
    echo "Error: KeycloakRealm '${name}' did not reconcile within ${max}s."
    keycloakrealm_status_hint "$ns" "$name" | sed 's/^/  /' || true
    echo "  Try: oc describe keycloakrealm -n ${ns} ${name}  (or keycloakrealms.k8s.keycloak.org/${name})"
    exit 1
}

wait_keycloak_client_reconciled_or_exit() {
    local ns=$1 name=$2
    local max="${MAX_WAIT_KC_REALM_CLIENT}"
    local w=0
    echo "Waiting for KeycloakClient '${name}' to reconcile (required; max ${max}s)..."
    while [ "$w" -lt "$max" ]; do
        if keycloakclient_is_reconciled "$ns" "$name"; then
            echo "✓ KeycloakClient '${name}' is reconciled"
            return 0
        fi
        sleep 5
        w=$((w + 5))
        if [ $((w % 10)) -eq 0 ] && [ "$w" -gt 0 ]; then
            echo "  Still waiting for client '${name}'... (${w}s/${max}s)"
            keycloakclient_status_hint "$ns" "$name" | sed 's/^/    | /' || true
        fi
    done
    echo "Error: KeycloakClient '${name}' did not reconcile within ${max}s."
    keycloakclient_status_hint "$ns" "$name" | sed 's/^/  /' || true
    echo "  Try: oc describe keycloakclient -n ${ns} ${name}"
    exit 1
}

wait_keycloak_user_reconciled_or_exit() {
    local ns=$1 name=$2
    local max="${MAX_WAIT_KC_USER}"
    local w=0
    if ! [ "${max}" -gt 0 ] 2>/dev/null; then
        echo "Error: MAX_WAIT_KC_USER must be a positive integer (got: ${max})"
        exit 1
    fi
    echo "Waiting for KeycloakUser '${name}' to reconcile (required; max ${max}s)..."
    while [ "$w" -lt "$max" ]; do
        if keycloakuser_is_reconciled "$ns" "$name"; then
            echo "✓ KeycloakUser '${name}' reconciled"
            return 0
        fi
        sleep 2
        w=$((w + 2))
        if [ $((w % 10)) -eq 0 ] && [ "$w" -gt 0 ]; then
            echo "  Still waiting for user '${name}'... (${w}s/${max}s)"
            keycloakuser_status_hint "$ns" "$name" | sed 's/^/    | /' || true
        fi
    done
    echo "Error: KeycloakUser '${name}' did not reconcile within ${max}s."
    keycloakuser_status_hint "$ns" "$name" | sed 's/^/  /' || true
    echo "  Try: oc describe keycloakuser -n ${ns} ${name}"
    exit 1
}

# Step 1: Get Red Hat SSO (Keycloak) OIDC Issuer URL
echo "Retrieving Red Hat SSO (Keycloak) OIDC Issuer URL..."

KEYCLOAK_NS=""
if KEYCLOAK_NS=$(discover_keycloak_namespace); then
    :
else
    KEYCLOAK_NS=""
fi

if [ -z "$KEYCLOAK_NS" ]; then
    echo "Error: Could not determine the Keycloak namespace."
    echo "Set KEYCLOAK_NAMESPACE (e.g. keycloak for rhbk-operator), or install Keycloak / RH SSO with ./01-keycloak.sh"
    exit 1
fi
echo "Using Keycloak namespace: ${KEYCLOAK_NS}"

# Determine the correct CRD name (try both singular and plural)
KEYCLOAK_CRD="keycloaks"
if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloaks.keycloak.org >/dev/null 2>&1; then
    KEYCLOAK_CRD="keycloaks"
elif oc get crd keycloak.k8s.keycloak.org >/dev/null 2>&1 || oc get crd keycloak.keycloak.org >/dev/null 2>&1; then
    KEYCLOAK_CRD="keycloak"
else
    # Try to determine by attempting to list resources
    if oc get keycloaks -n "$KEYCLOAK_NS" >/dev/null 2>&1; then
        KEYCLOAK_CRD="keycloaks"
    elif oc get keycloak -n "$KEYCLOAK_NS" >/dev/null 2>&1; then
        KEYCLOAK_CRD="keycloak"
    else
        KEYCLOAK_CRD="keycloak"
    fi
fi

KEYCLOAK_CR_NAME="rhsso-instance"

# Check if Keycloak CR exists, or if resources are running
KEYCLOAK_CR_EXISTS=false
if oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n "$KEYCLOAK_NS" >/dev/null 2>&1; then
    KEYCLOAK_CR_EXISTS=true
elif oc get $KEYCLOAK_CRD keycloak -n "$KEYCLOAK_NS" >/dev/null 2>&1; then
    KEYCLOAK_CR_NAME="keycloak"
    KEYCLOAK_CR_EXISTS=true
else
    # Check if resources are running even without CR
    KEYCLOAK_STS_READY=$(oc get statefulset keycloak -n "$KEYCLOAK_NS" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
    KEYCLOAK_POD_RUNNING=$(oc get pod -n "$KEYCLOAK_NS" -l app=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    
    if [ "$KEYCLOAK_STS_READY" = "1/1" ] && [ "$KEYCLOAK_POD_RUNNING" = "Running" ]; then
        echo "✓ Keycloak resources are running (CR not found, but installation appears successful)"
        KEYCLOAK_CR_EXISTS=false
    else
        echo "Keycloak CR not found; waiting for instance pods / StatefulSet / Deployment in ${KEYCLOAK_NS} (up to 300s)..."
        KEYCLOAK_WORKLOAD_OK=false
        _pre=0
        while [ "$_pre" -lt 300 ]; do
            KEYCLOAK_STS_READY=$(oc get statefulset keycloak -n "$KEYCLOAK_NS" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
            KEYCLOAK_POD_RUNNING=$(oc get pod -n "$KEYCLOAK_NS" -l app=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
            if [ "$KEYCLOAK_STS_READY" = "1/1" ] && [ "$KEYCLOAK_POD_RUNNING" = "Running" ]; then
                echo "✓ Keycloak resources are running (StatefulSet + pods)"
                KEYCLOAK_WORKLOAD_OK=true
                break
            fi
            _k_r=$(oc get deployment -n "$KEYCLOAK_NS" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "")
            _k_w=$(oc get deployment -n "$KEYCLOAK_NS" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo "")
            if [ -n "$_k_r" ] && [ -n "$_k_w" ] && [ "$_k_w" != "0" ] && [ "$_k_r" = "$_k_w" ]; then
                echo "✓ Keycloak Deployment ready (Red Hat build of Keycloak)"
                KEYCLOAK_WORKLOAD_OK=true
                break
            fi
            if oc get pods -n "$KEYCLOAK_NS" -l app.kubernetes.io/name=keycloak --field-selector=status.phase=Running -o name 2>/dev/null | grep -q .; then
                echo "✓ Keycloak instance pods Running (app.kubernetes.io/name=keycloak)"
                KEYCLOAK_WORKLOAD_OK=true
                break
            fi
            if oc get pods -n "$KEYCLOAK_NS" --no-headers 2>/dev/null | awk '$3=="Running"' | grep -qiE 'keycloak|rhbk'; then
                echo "✓ Keycloak-related pods Running in ${KEYCLOAK_NS}"
                KEYCLOAK_WORKLOAD_OK=true
                break
            fi
            sleep 5
            _pre=$((_pre + 5))
            if [ $((_pre % 30)) -eq 0 ] && [ "$_pre" -gt 0 ]; then
                echo "  ... still waiting (${_pre}s/300s) for Keycloak workload in ${KEYCLOAK_NS}"
            fi
        done
        if [ "$KEYCLOAK_WORKLOAD_OK" != true ]; then
            echo "Error: Keycloak custom resource not found in namespace ${KEYCLOAK_NS} and no healthy Keycloak workload detected"
            echo "Install RH SSO (./01-keycloak.sh) or Red Hat build of Keycloak, or set KEYCLOAK_NAMESPACE / KEYCLOAK_NAMESPACE_OVERRIDE"
            exit 1
        fi
        KEYCLOAK_CR_EXISTS=false
    fi
fi

KEYCLOAK_ROUTE=""
for _rt in keycloak-rhsso keycloak rhbk-keycloak; do
    KEYCLOAK_ROUTE=$(oc get route "$_rt" -n "$KEYCLOAK_NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    [ -n "$KEYCLOAK_ROUTE" ] && break
done
if [ -z "$KEYCLOAK_ROUTE" ]; then
    # RHBK / single-route installs: any route in the namespace whose name suggests Keycloak
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        _rn="${line%% *}"
        case "$_rn" in *keycloak*|*rhbk*|*sso*) KEYCLOAK_ROUTE=$(oc get route "$_rn" -n "$KEYCLOAK_NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
            [ -n "$KEYCLOAK_ROUTE" ] && break
            ;;
        esac
    done < <(oc get route -n "$KEYCLOAK_NS" --no-headers 2>/dev/null | awk '{print $1}')
fi
if [ -z "$KEYCLOAK_ROUTE" ]; then
    KEYCLOAK_ROUTE=$(oc get routes -n "$KEYCLOAK_NS" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -m1 '[[:alnum:]]' || true)
fi
if [ -z "$KEYCLOAK_ROUTE" ]; then
    echo "Error: Could not retrieve a Keycloak route host in namespace ${KEYCLOAK_NS}"
    echo "Keycloak may still be installing. Try: oc get route -n ${KEYCLOAK_NS}"
    exit 1
fi

KEYCLOAK_URL="https://${KEYCLOAK_ROUTE}"
if [ -n "${OIDC_ISSUER_URL:-}" ]; then
    echo "✓ Using OIDC_ISSUER_URL from environment: $OIDC_ISSUER_URL"
else
    OIDC_ISSUER_URL=$(discover_keycloak_oidc_issuer_url "$KEYCLOAK_ROUTE" openshift)
fi
echo "✓ Red Hat SSO (Keycloak) URL: $KEYCLOAK_URL"
echo "✓ OIDC Issuer URL: $OIDC_ISSUER_URL"

# Step 2: Wait for Keycloak instance to be ready before creating realms/clients
echo "Waiting for Keycloak instance to be ready..."
KEYCLOAK_CR_NAME="rhsso-instance"
KEYCLOAK_CRD="keycloaks"
if ! oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n "$KEYCLOAK_NS" >/dev/null 2>&1; then
    KEYCLOAK_CRD="keycloak"
fi

MAX_WAIT_KEYCLOAK=300
WAIT_COUNT=0
KEYCLOAK_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT_KEYCLOAK ]; do
    # First check CR status if CR exists
    KEYCLOAK_READY_STATUS=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n "$KEYCLOAK_NS" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    KEYCLOAK_PHASE=$(oc get $KEYCLOAK_CRD $KEYCLOAK_CR_NAME -n "$KEYCLOAK_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    
    # Check if CR status indicates ready
    if [ "$KEYCLOAK_READY_STATUS" = "true" ] || [ "$KEYCLOAK_PHASE" = "reconciled" ]; then
        KEYCLOAK_READY=true
        echo "✓ Keycloak instance is ready (CR status)"
        break
    fi
    
    # Fallback: Check if Keycloak pods are running (RH-SSO label or RHBK operator label)
    KEYCLOAK_PODS_READY=$(oc get pods -n "$KEYCLOAK_NS" -l app=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [ "$KEYCLOAK_PODS_READY" != "Running" ]; then
        KEYCLOAK_PODS_READY=$(oc get pods -n "$KEYCLOAK_NS" -l app.kubernetes.io/name=keycloak --field-selector=status.phase=Running -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    fi
    if [ "$KEYCLOAK_PODS_READY" = "Running" ]; then
        # Check if route exists and pods are running - consider it ready
        if [ -n "$KEYCLOAK_ROUTE" ]; then
            KEYCLOAK_READY=true
            echo "✓ Keycloak instance is ready (pods running and route available)"
            break
        else
            # If pods are running but no route check, consider it ready
            KEYCLOAK_READY=true
            echo "✓ Keycloak instance is ready (pods running)"
            break
        fi
    fi
    
    # Alternative: Check StatefulSet ready replicas
    KEYCLOAK_STS_READY=$(oc get statefulset keycloak -n "$KEYCLOAK_NS" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "")
    if [ -n "$KEYCLOAK_STS_READY" ] && [ "$KEYCLOAK_STS_READY" != "0/0" ] && [ "$KEYCLOAK_STS_READY" != "/" ]; then
        READY_REPLICAS=$(echo "$KEYCLOAK_STS_READY" | cut -d'/' -f1)
        TOTAL_REPLICAS=$(echo "$KEYCLOAK_STS_READY" | cut -d'/' -f2)
        if [ "$READY_REPLICAS" -ge 1 ] && [ "$READY_REPLICAS" = "$TOTAL_REPLICAS" ] 2>/dev/null; then
            KEYCLOAK_READY=true
            echo "✓ Keycloak instance is ready (StatefulSet ready)"
            break
        fi
    fi

    # RHBK: Deployment with app.kubernetes.io/name=keycloak
    _k_r=$(oc get deployment -n "$KEYCLOAK_NS" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "")
    _k_w=$(oc get deployment -n "$KEYCLOAK_NS" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo "")
    if [ -n "$_k_r" ] && [ -n "$_k_w" ] && [ "$_k_w" != "0" ] && [ "$_k_r" = "$_k_w" ] && [ -n "$KEYCLOAK_ROUTE" ]; then
        KEYCLOAK_READY=true
        echo "✓ Keycloak instance is ready (RHBK Deployment + route)"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for Keycloak instance... (${WAIT_COUNT}s/${MAX_WAIT_KEYCLOAK}s) - Phase: ${KEYCLOAK_PHASE:-unknown}, Ready: ${KEYCLOAK_READY_STATUS:-false}, Pods: ${KEYCLOAK_PODS_READY:-none}"
    fi
done

if [ "$KEYCLOAK_READY" = false ]; then
    echo "Error: Keycloak instance did not become ready within ${MAX_WAIT_KEYCLOAK} seconds."
    echo "  Current status:"
    oc get pods -n "$KEYCLOAK_NS" -l app=keycloak 2>/dev/null || true
    oc get pods -n "$KEYCLOAK_NS" -l app.kubernetes.io/name=keycloak 2>/dev/null || echo "  No Keycloak-labeled pods found"
    oc get route keycloak-rhsso -n "$KEYCLOAK_NS" 2>/dev/null || oc get route keycloak -n "$KEYCLOAK_NS" 2>/dev/null || oc get route -n "$KEYCLOAK_NS" 2>/dev/null || echo "  No routes in namespace"
    exit 1
fi

# KeycloakRealm / KeycloakClient / KeycloakUser: must reconcile before RHTAS install continues. Override timeouts via env.
MAX_WAIT_KC_REALM_CLIENT="${MAX_WAIT_KC_REALM_CLIENT:-600}"
MAX_WAIT_KC_USER="${MAX_WAIT_KC_USER:-300}"

# Step 3: Ensure OpenShift realm exists (using KeycloakRealm CR)
echo ""
echo "Ensuring OpenShift realm exists..."
REALM="openshift"
REALM_CR_NAME="openshift"

# Check if KeycloakRealm CR exists (k8s.keycloak.org or legacy keycloak.org)
if keycloakrealm_cr_exists "$KEYCLOAK_NS" "$REALM_CR_NAME"; then
    echo "✓ KeycloakRealm CR '${REALM_CR_NAME}' already exists"
else
    echo "Creating KeycloakRealm CR '${REALM_CR_NAME}'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakRealm
metadata:
  name: ${REALM_CR_NAME}
  namespace: ${KEYCLOAK_NS}
  labels:
    app: openshift
spec:
  instanceSelector:
    matchLabels:
      app: sso
  realm:
    displayName: Openshift Authentication Realm
    enabled: true
    id: ${REALM}
    realm: ${REALM}
EOF
    then
        echo "Error: Failed to create KeycloakRealm CR"
        exit 1
    fi
    
    echo "✓ KeycloakRealm CR created successfully"
fi
wait_keycloak_realm_reconciled_or_exit "$KEYCLOAK_NS" "$REALM_CR_NAME"

# Step 3a: Create OpenShift OAuth Client
echo ""
echo "Creating OpenShift OAuth Client..."
CLIENT_CR_NAME_OCP="openshift"
CLIENT_YAML_FILE="${SCRIPT_DIR}/keycloak-client-openshift.yaml"

if keycloakclient_cr_exists "$KEYCLOAK_NS" "$CLIENT_CR_NAME_OCP"; then
    echo "✓ KeycloakClient CR '${CLIENT_CR_NAME_OCP}' already exists"
else
    echo "Creating KeycloakClient CR '${CLIENT_CR_NAME_OCP}' from ${CLIENT_YAML_FILE}..."
    
    if [ ! -f "$CLIENT_YAML_FILE" ]; then
        echo "Error: YAML file not found: ${CLIENT_YAML_FILE}"
        exit 1
    fi
    
    if ! oc apply -f "$CLIENT_YAML_FILE"; then
        echo "Error: Failed to create KeycloakClient CR"
        exit 1
    fi
    
    echo "✓ KeycloakClient CR created successfully"
fi
wait_keycloak_client_reconciled_or_exit "$KEYCLOAK_NS" "$CLIENT_CR_NAME_OCP"

# Step 4: Create Keycloak User for authentication
echo ""
echo "Creating Keycloak User for authentication..."
KEYCLOAK_USER_NAME="admin"
KEYCLOAK_USER_USERNAME="admin"
KEYCLOAK_USER_EMAIL="admin@demo.redhat.com"
KEYCLOAK_USER_PASSWORD="116608"  # Default password, can be changed

# Check if KeycloakUser CR already exists
if keycloakuser_cr_exists "$KEYCLOAK_NS" "$KEYCLOAK_USER_NAME"; then
    echo "✓ KeycloakUser CR '${KEYCLOAK_USER_NAME}' already exists"
else
    echo "Creating KeycloakUser CR '${KEYCLOAK_USER_NAME}'..."
    
    # Encode password to base64
    KEYCLOAK_USER_PASSWORD_B64=$(echo -n "$KEYCLOAK_USER_PASSWORD" | base64)
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakUser
metadata:
  name: ${KEYCLOAK_USER_NAME}
  namespace: ${KEYCLOAK_NS}
  labels:
    app: openshift
spec:
  realmSelector:
    matchLabels:
      app: openshift
  user:
    username: ${KEYCLOAK_USER_USERNAME}
    email: ${KEYCLOAK_USER_EMAIL}
    emailVerified: true
    enabled: true
    credentials:
      - type: password
        value: ${KEYCLOAK_USER_PASSWORD_B64}
EOF
    then
        echo "Error: Failed to create KeycloakUser CR"
        exit 1
    fi
    
    echo "✓ KeycloakUser CR created successfully"
fi
wait_keycloak_user_reconciled_or_exit "$KEYCLOAK_NS" "$KEYCLOAK_USER_NAME"

# Step 3b: Create jdoe Keycloak User for signing
echo ""
echo "Creating jdoe Keycloak User for signing..."
KEYCLOAK_USER_NAME_JDOE="jdoe"
KEYCLOAK_USER_USERNAME_JDOE="jdoe"
KEYCLOAK_USER_EMAIL_JDOE="jdoe@redhat.com"
KEYCLOAK_USER_PASSWORD_JDOE="secure"

# Check if KeycloakUser CR already exists
if keycloakuser_cr_exists "$KEYCLOAK_NS" "$KEYCLOAK_USER_NAME_JDOE"; then
    echo "✓ KeycloakUser CR '${KEYCLOAK_USER_NAME_JDOE}' already exists"
else
    echo "Creating KeycloakUser CR '${KEYCLOAK_USER_NAME_JDOE}'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakUser
metadata:
  name: ${KEYCLOAK_USER_NAME_JDOE}
  namespace: ${KEYCLOAK_NS}
  labels:
    app: trusted-artifact-signer
spec:
  realmSelector:
    matchLabels:
      app: openshift
  user:
    username: ${KEYCLOAK_USER_USERNAME_JDOE}
    email: ${KEYCLOAK_USER_EMAIL_JDOE}
    emailVerified: true
    enabled: true
    firstName: Jane
    lastName: Doe
    credentials:
      - type: password
        value: ${KEYCLOAK_USER_PASSWORD_JDOE}
EOF
    then
        echo "Error: Failed to create KeycloakUser CR for jdoe"
        exit 1
    fi
    
    echo "✓ KeycloakUser CR created successfully"
fi
wait_keycloak_user_reconciled_or_exit "$KEYCLOAK_NS" "$KEYCLOAK_USER_NAME_JDOE"

# Step 3c: Create user1 Keycloak User
echo ""
echo "Creating user1 Keycloak User..."
KEYCLOAK_USER_NAME_USER1="user1"
USER_YAML_FILE="${SCRIPT_DIR}/keycloak-user-user1.yaml"

# Check if KeycloakUser CR already exists
if keycloakuser_cr_exists "$KEYCLOAK_NS" "$KEYCLOAK_USER_NAME_USER1"; then
    echo "✓ KeycloakUser CR '${KEYCLOAK_USER_NAME_USER1}' already exists"
else
    echo "Creating KeycloakUser CR '${KEYCLOAK_USER_NAME_USER1}' from ${USER_YAML_FILE}..."
    
    if [ ! -f "$USER_YAML_FILE" ]; then
        echo "Error: YAML file not found: ${USER_YAML_FILE}"
        exit 1
    fi
    
    if ! oc apply -f "$USER_YAML_FILE"; then
        echo "Error: Failed to create KeycloakUser CR"
        exit 1
    fi
    
    echo "✓ KeycloakUser CR created successfully"
fi
wait_keycloak_user_reconciled_or_exit "$KEYCLOAK_NS" "$KEYCLOAK_USER_NAME_USER1"

# Step 4: Create OAuth Client in Red Hat SSO (Keycloak) for Trusted Artifact Signer
echo ""
echo "Creating OAuth Client in Red Hat SSO (Keycloak) for Trusted Artifact Signer..."
OIDC_CLIENT_ID="trusted-artifact-signer"
CLIENT_CR_NAME="trusted-artifact-signer"

# Check if KeycloakClient CR already exists
if keycloakclient_cr_exists "$KEYCLOAK_NS" "$CLIENT_CR_NAME"; then
    echo "✓ KeycloakClient CR '${CLIENT_CR_NAME}' already exists"
else
    echo "Creating KeycloakClient CR '${CLIENT_CR_NAME}'..."
    
    if ! cat <<EOF | oc apply -f -
apiVersion: keycloak.org/v1alpha1
kind: KeycloakClient
metadata:
  name: ${CLIENT_CR_NAME}
  namespace: ${KEYCLOAK_NS}
  labels:
    app: keycloak
spec:
  realmSelector:
    matchLabels:
      app: openshift
  client:
    clientId: ${OIDC_CLIENT_ID}
    enabled: true
    protocol: openid-connect
    publicClient: true
    standardFlowEnabled: true
    directAccessGrantsEnabled: true
    redirectUris:
      - "http://localhost/auth/callback"
      - "urn:ietf:wg:oauth:2.0:oob"
    webOrigins:
      - "+"
    defaultClientScopes:
      - profile
      - email
    defaultScopes:
      - "openid"
      - "email"
    protocolMappers:
      - name: audience-mapper
        protocol: openid-connect
        protocolMapper: oidc-audience-mapper
        config:
          included.client.audience: "${OIDC_CLIENT_ID}"
          id.token.claim: "true"
          access.token.claim: "true"
    attributes:
      access.token.lifespan: "300"
EOF
    # Note: The protocol mapper sets the audience (aud) claim to the client ID (${OIDC_CLIENT_ID})
    # which is "trusted-artifact-signer". This matches what Fulcio expects for OIDC token verification.
    then
        echo "Error: Failed to create KeycloakClient CR"
        exit 1
    fi
    
    echo "✓ KeycloakClient CR created successfully"
    
    echo ""
    echo "NOTE: If the protocol mapper is not supported by the KeycloakClient CRD, you may need to"
    echo "manually configure the Audience protocol mapper in Keycloak admin console:"
    echo "  1. Log into Keycloak admin console"
    echo "  2. Navigate to Clients -> ${OIDC_CLIENT_ID}"
    echo "  3. Go to Client scopes tab -> ${OIDC_CLIENT_ID}-dedicated -> Mappers"
    echo "  4. Add mapper -> By configuration -> Audience"
    echo "  5. Set 'Included Client Audience' to '${OIDC_CLIENT_ID}'"
    echo "  6. Enable 'Add to ID token' and 'Add to access token'"
    echo ""
fi
wait_keycloak_client_reconciled_or_exit "$KEYCLOAK_NS" "$CLIENT_CR_NAME"

# Check if client secret was created
CLIENT_SECRET_NAME="keycloak-client-secret-${CLIENT_CR_NAME}"
if oc get secret $CLIENT_SECRET_NAME -n "$KEYCLOAK_NS" >/dev/null 2>&1; then
    echo "✓ Client secret '${CLIENT_SECRET_NAME}' exists"
    CLIENT_ID_FROM_SECRET=$(oc get secret $CLIENT_SECRET_NAME -n "$KEYCLOAK_NS" -o jsonpath='{.data.CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "$CLIENT_ID_FROM_SECRET" ]; then
        echo "  Client ID from secret: ${CLIENT_ID_FROM_SECRET}"
    fi
else
    echo "Note: Client secret '${CLIENT_SECRET_NAME}' not yet created (may be created after Trusted Artifact Signer installation)"
fi

# Step 5: Install RHTAS Operator
echo "Installing RHTAS Operator..."

# Ensure we're targeting the correct namespace
OPERATOR_NAMESPACE="openshift-operators"

# OLM Subscription (use full API; short name "subscription" resolves to ACM on many clusters)
OLM_SUB="subscription.operators.coreos.com"

# Check if subscription already exists in the correct namespace
if oc get "${OLM_SUB}" trusted-artifact-signer -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
    echo "RHTAS Operator subscription 'trusted-artifact-signer' already exists in $OPERATOR_NAMESPACE, skipping creation"
else
    # Clean up any subscriptions in wrong namespaces (optional, but helpful)
    echo "Checking for subscriptions in incorrect namespaces..."
    WRONG_SUBS=$(oc get "${OLM_SUB}" -A -o jsonpath='{range .items[?(@.metadata.name=="trusted-artifact-signer" && @.metadata.namespace!="openshift-operators")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
    if [ -n "$WRONG_SUBS" ]; then
        echo "Warning: Found subscriptions in incorrect namespaces:"
        echo "$WRONG_SUBS" | while read -r ns name; do
            echo "  - $ns/$name"
        done
        echo "  These should only exist in $OPERATOR_NAMESPACE namespace"
        echo "  To clean them up, run: oc delete ${OLM_SUB} trusted-artifact-signer -n <namespace>"
    fi
    
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: trusted-artifact-signer
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhtas-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: rhtas-operator.v1.3.1
EOF
    echo "✓ RHTAS Operator subscription created in $OPERATOR_NAMESPACE namespace"
fi

# Some clusters require InstallPlan approval even when spec.installPlanApproval is Automatic (policy / OLM).
approve_rhtas_installplan_if_needed() {
    local ip approved
    ip=$(oc get "${OLM_SUB}" trusted-artifact-signer -n "$OPERATOR_NAMESPACE" -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || echo "")
    [ -z "$ip" ] && return 0
    approved=$(oc get installplan.operators.coreos.com "$ip" -n "$OPERATOR_NAMESPACE" -o jsonpath='{.spec.approved}' 2>/dev/null || echo "false")
    if [ "$approved" != "true" ]; then
        echo "  Approving InstallPlan '$ip' (pending approval — CSV will not exist until this is done)..."
        oc patch installplan.operators.coreos.com "$ip" -n "$OPERATOR_NAMESPACE" --type merge -p '{"spec":{"approved":true}}' &>/dev/null || \
            oc patch installplan "$ip" -n "$OPERATOR_NAMESPACE" --type merge -p '{"spec":{"approved":true}}' &>/dev/null || true
    fi
}

# Wait for RHTAS Operator to be ready
echo "Waiting for RHTAS Operator to be ready..."

# First, wait for CSV to appear
echo "Waiting for CSV to be created..."
CSV_NAME=""
MAX_WAIT_CSV=300
WAIT_COUNT=0

approve_rhtas_installplan_if_needed

while [ $WAIT_COUNT -lt $MAX_WAIT_CSV ]; do
    approve_rhtas_installplan_if_needed

    # Try multiple methods to find the CSV
    CSV_NAME=$(oc get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName=="Trusted Artifact Signer Operator")].metadata.name}' 2>/dev/null || echo "")
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n openshift-operators -o name 2>/dev/null | grep -iE "trusted-artifact-signer|rhtas-operator" | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    fi
    if [ -z "$CSV_NAME" ]; then
        CSV_NAME=$(oc get csv -n openshift-operators -l operators.coreos.com/trusted-artifact-signer.openshift-operators -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi

    if [ -n "$CSV_NAME" ]; then
        echo "✓ Found CSV: $CSV_NAME"
        break
    fi

    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for CSV to appear... (${WAIT_COUNT}s/${MAX_WAIT_CSV}s)"
        echo "    Checking available CSVs..."
        oc get csv -n openshift-operators -o name 2>/dev/null | grep -i rhtas | head -3 || oc get csv -n openshift-operators -o name 2>/dev/null | head -3 || echo "    No CSVs found yet"
    fi
done

if [ -z "$CSV_NAME" ]; then
    echo "Error: Could not find RHTAS Operator CSV after ${MAX_WAIT_CSV} seconds"
    echo "If InstallPlan is pending approval, the script should approve it automatically; check RBAC (cluster-admin) and:"
    echo "  oc get installplan -n openshift-operators"
    echo "  oc get csv -n openshift-operators | grep -iE 'rhtas|trusted-artifact-signer'"
    echo "  oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator"
    exit 1
fi

# OLM can leave CSV in Installing for a long time after the operator Deployment/Pods are actually ready.
# Prefer exiting this wait when openshift-operators shows a healthy operator workload.
rhtas_operator_controller_ready() {
    local dep ready want n
    n=$(oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    if [ "${n:-0}" -ge 1 ]; then
        ready=$(oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.ready}{"\n"}{end}{end}' 2>/dev/null | grep -c true || echo 0)
        if [ "${ready:-0}" -ge 1 ]; then
            return 0
        fi
    fi
    dep=$(oc get deployment -n openshift-operators -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -iE 'trusted-artifact-signer|rhtas' | head -1)
    if [ -n "$dep" ]; then
        ready=$(oc get deployment "$dep" -n openshift-operators -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
        want=$(oc get deployment "$dep" -n openshift-operators -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)
        if [ -n "${ready:-}" ] && [ "${want:-1}" != "0" ] && [ "$ready" = "$want" ]; then
            return 0
        fi
    fi
    return 1
}

# Wait for CSV to be in Succeeded phase AND deployment to be ready
echo "Waiting for RHTAS operator to be ready (preferring live Deployment/Pods over CSV phase alone)..."
MAX_WAIT_CSV_INSTALL=600
WAIT_COUNT=0
CSV_SUCCEEDED=false
DEPLOYMENT_READY=false

# Find the deployment name
DEPLOYMENT_NAME=""
while [ $WAIT_COUNT -lt $MAX_WAIT_CSV_INSTALL ]; do
    if rhtas_operator_controller_ready; then
        CSV_PHASE=$(oc get csv "$CSV_NAME" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        echo "✓ RHTAS operator controller is ready in openshift-operators (CSV phase: ${CSV_PHASE:-unknown} — continuing without waiting only on CSV Succeeded)"
        CSV_SUCCEEDED=true
        DEPLOYMENT_READY=true
        break
    fi

    CSV_PHASE=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    CSV_CONDITIONS=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
    
    # Try to find the deployment name from CSV
    if [ -z "$DEPLOYMENT_NAME" ]; then
        DEPLOYMENT_NAME=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.spec.install.spec.deployments[*].name}' 2>/dev/null | awk '{print $1}' || echo "")
        if [ -z "$DEPLOYMENT_NAME" ]; then
            # Try alternative method - look for deployments with operator name
            DEPLOYMENT_NAME=$(oc get deployment -n openshift-operators -o name 2>/dev/null | grep -i "rhtas\|trusted-artifact-signer" | head -1 | sed 's|deployment.apps/||' || echo "")
        fi
    fi
    
    # Check CSV phase
    if [ "$CSV_PHASE" = "Succeeded" ]; then
        CSV_SUCCEEDED=true
        
        # Also check if deployment is actually ready
        if [ -n "$DEPLOYMENT_NAME" ]; then
            DEPLOYMENT_READY_REPLICAS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            DEPLOYMENT_REPLICAS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
            
            if [ "$DEPLOYMENT_READY_REPLICAS" = "$DEPLOYMENT_REPLICAS" ] && [ "$DEPLOYMENT_READY_REPLICAS" != "0" ]; then
                DEPLOYMENT_READY=true
                echo "✓ CSV is in Succeeded phase"
                echo "✓ Deployment $DEPLOYMENT_NAME is ready ($DEPLOYMENT_READY_REPLICAS/$DEPLOYMENT_REPLICAS replicas)"
                break
            else
                # CSV says succeeded but deployment isn't ready yet
                if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
                    echo "  CSV is Succeeded but deployment not ready yet... (${WAIT_COUNT}s/${MAX_WAIT_CSV_INSTALL}s)"
                    echo "    Deployment $DEPLOYMENT_NAME: $DEPLOYMENT_READY_REPLICAS/$DEPLOYMENT_REPLICAS replicas ready"
                    # Check deployment conditions
                    DEPLOYMENT_CONDITIONS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
                    if [ -n "$DEPLOYMENT_CONDITIONS" ]; then
                        echo "    Deployment conditions: ${DEPLOYMENT_CONDITIONS}"
                    fi
                fi
            fi
        else
            # Can't find deployment, but CSV is succeeded - might be OK
            echo "✓ CSV is in Succeeded phase (deployment name not found, will check pods)"
            break
        fi
    elif [ "$CSV_PHASE" = "Failed" ]; then
        echo "Error: CSV installation failed. Phase: $CSV_PHASE"
        echo "CSV conditions:"
        oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.conditions[*]}' 2>/dev/null || echo "  No conditions found"
        exit 1
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for CSV installation... (${WAIT_COUNT}s/${MAX_WAIT_CSV_INSTALL}s) - Phase: ${CSV_PHASE:-Unknown}"
        if [ -n "$CSV_CONDITIONS" ]; then
            echo "    Conditions: ${CSV_CONDITIONS}"
        fi
        if [ -n "$DEPLOYMENT_NAME" ]; then
            DEPLOYMENT_STATUS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
            echo "    Deployment $DEPLOYMENT_NAME Available status: ${DEPLOYMENT_STATUS:-Unknown}"
        fi
    fi
done

if [ "$CSV_SUCCEEDED" = false ]; then
    echo "Warning: CSV did not reach Succeeded phase within ${MAX_WAIT_CSV_INSTALL} seconds"
    echo "Current CSV status:"
    oc get csv $CSV_NAME -n openshift-operators -o yaml | grep -A 10 "status:" || echo "  Could not retrieve CSV status"
    echo ""
    echo "Continuing, but operator may not be fully ready..."
elif [ "$DEPLOYMENT_READY" = false ] && [ -n "$DEPLOYMENT_NAME" ]; then
    echo "Warning: CSV is Succeeded but deployment $DEPLOYMENT_NAME is not ready"
    echo "Deployment status:"
    oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o yaml | grep -A 15 "status:" || echo "  Could not retrieve deployment status"
    echo ""
    echo "Checking deployment events:"
    oc get events -n openshift-operators --field-selector involvedObject.name=$DEPLOYMENT_NAME --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -5 || echo "  No recent events"
    echo ""
    echo "Continuing, but operator pods may not be running..."
fi

# Wait for CRDs to be installed
echo ""
echo "Waiting for RHTAS CRDs to be installed..."
MAX_WAIT_CRD=300
WAIT_COUNT=0
CRDS_INSTALLED=false

REQUIRED_CRDS=(
    "securesigns.rhtas.redhat.com"
    "tufs.rhtas.redhat.com"
    "fulcios.rhtas.redhat.com"
    "rekors.rhtas.redhat.com"
)

while [ $WAIT_COUNT -lt $MAX_WAIT_CRD ]; do
    ALL_CRDS_EXIST=true
    MISSING_CRDS=""
    
    for crd in "${REQUIRED_CRDS[@]}"; do
        if ! oc get crd "$crd" >/dev/null 2>&1; then
            ALL_CRDS_EXIST=false
            MISSING_CRDS="${MISSING_CRDS} ${crd}"
        fi
    done
    
    if [ "$ALL_CRDS_EXIST" = true ]; then
        CRDS_INSTALLED=true
        echo "✓ All required CRDs are installed"
        break
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for CRDs... (${WAIT_COUNT}s/${MAX_WAIT_CRD}s)"
        echo "    Missing CRDs:${MISSING_CRDS}"
    fi
done

if [ "$CRDS_INSTALLED" = false ]; then
    echo "Error: Required CRDs were not installed within ${MAX_WAIT_CRD} seconds"
    echo "Missing CRDs:${MISSING_CRDS}"
    echo ""
    echo "Please check operator logs:"
    echo "  oc logs -n openshift-operators -l name=trusted-artifact-signer-operator --tail=50"
    exit 1
fi

# Wait for operator pods to be running (skip if we already confirmed controller readiness above)
echo ""
if [ "$DEPLOYMENT_READY" = true ]; then
    echo "RHTAS operator pods already verified — skipping duplicate wait."
    OPERATOR_PODS_READY=true
else
echo "Waiting for RHTAS operator pods to be running..."

# Find deployment name if not already found
if [ -z "$DEPLOYMENT_NAME" ]; then
    DEPLOYMENT_NAME=$(oc get deployment -n openshift-operators -o name 2>/dev/null | grep -i "rhtas\|trusted-artifact-signer\|controller-manager" | head -1 | sed 's|deployment.apps/||' || echo "")
    if [ -z "$DEPLOYMENT_NAME" ]; then
        # Try to get from CSV
        DEPLOYMENT_NAME=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.spec.install.spec.deployments[*].name}' 2>/dev/null | awk '{print $1}' || echo "")
    fi
fi

MAX_WAIT_PODS=300
WAIT_COUNT=0
OPERATOR_PODS_READY=false

while [ $WAIT_COUNT -lt $MAX_WAIT_PODS ]; do
    # First check deployment status if we found it
    if [ -n "$DEPLOYMENT_NAME" ]; then
        DEPLOYMENT_READY_REPLICAS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        DEPLOYMENT_REPLICAS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        DEPLOYMENT_AVAILABLE=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        
        if [ "$DEPLOYMENT_READY_REPLICAS" = "$DEPLOYMENT_REPLICAS" ] && [ "$DEPLOYMENT_READY_REPLICAS" != "0" ] && [ "$DEPLOYMENT_AVAILABLE" = "True" ]; then
            OPERATOR_PODS_READY=true
            echo "✓ Deployment $DEPLOYMENT_NAME is ready ($DEPLOYMENT_READY_REPLICAS/$DEPLOYMENT_REPLICAS replicas)"
            break
        fi
    fi
    
    # Also check pods directly
    OPERATOR_PODS=$(oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "$OPERATOR_PODS" -gt 0 ]; then
        # Check if pods are actually ready
        READY_PODS=$(oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator --field-selector=status.phase=Running -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null | wc -w || echo "0")
        if [ "$READY_PODS" -gt 0 ]; then
            OPERATOR_PODS_READY=true
            echo "✓ Operator pods are running and ready"
            break
        fi
    fi
    
    sleep 5
    WAIT_COUNT=$((WAIT_COUNT + 5))
    if [ $((WAIT_COUNT % 30)) -eq 0 ] && [ $WAIT_COUNT -gt 0 ]; then
        echo "  Still waiting for operator pods... (${WAIT_COUNT}s/${MAX_WAIT_PODS}s)"
        echo "    Operator pods status:"
        oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator 2>/dev/null || echo "    No operator pods found"
        
        # Check for deployments
        echo "    Checking for operator deployment:"
        if [ -n "$DEPLOYMENT_NAME" ]; then
            oc get deployment $DEPLOYMENT_NAME -n openshift-operators 2>/dev/null || echo "    Deployment $DEPLOYMENT_NAME not found"
            if [ -n "$DEPLOYMENT_NAME" ]; then
                DEPLOYMENT_STATUS=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
                DEPLOYMENT_MSG=$(oc get deployment $DEPLOYMENT_NAME -n openshift-operators -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null || echo "")
                echo "    Deployment $DEPLOYMENT_NAME Available: ${DEPLOYMENT_STATUS:-Unknown}"
                if [ -n "$DEPLOYMENT_MSG" ]; then
                    echo "    Message: $DEPLOYMENT_MSG"
                fi
            fi
        else
            oc get deployment -n openshift-operators -l name=trusted-artifact-signer-operator 2>/dev/null || echo "    No deployment found"
        fi
        
        # Check for any pods with errors
        echo "    Checking for pods in error states:"
        oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator --field-selector=status.phase!=Running 2>/dev/null || echo "    No non-running pods found"
        
        # Check ReplicaSet status if deployment exists
        if [ -n "$DEPLOYMENT_NAME" ]; then
            RS_NAME=$(oc get replicaset -n openshift-operators -l app=$DEPLOYMENT_NAME --sort-by='.metadata.creationTimestamp' -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
            if [ -n "$RS_NAME" ]; then
                RS_READY=$(oc get replicaset $RS_NAME -n openshift-operators -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                RS_REPLICAS=$(oc get replicaset $RS_NAME -n openshift-operators -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
                echo "    ReplicaSet $RS_NAME: $RS_READY/$RS_REPLICAS ready"
            fi
        fi
        
        # Check CSV conditions for clues
        echo "    CSV conditions:"
        oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.conditions[*].type}{"\n"}' 2>/dev/null | while read -r cond; do
            if [ -n "$cond" ]; then
                cond_status=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath="{.status.conditions[?(@.type==\"$cond\")].status}" 2>/dev/null || echo "")
                cond_msg=$(oc get csv $CSV_NAME -n openshift-operators -o jsonpath="{.status.conditions[?(@.type==\"$cond\")].message}" 2>/dev/null || echo "")
                if [ "$cond_status" != "True" ] && [ -n "$cond_msg" ]; then
                    echo "      $cond: $cond_status - $cond_msg"
                fi
            fi
        done
        
        # Check recent events
        echo "    Recent events in openshift-operators namespace:"
        oc get events -n openshift-operators --field-selector involvedObject.name=$CSV_NAME --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -3 || echo "    No recent events found"
    fi
done

if [ "$OPERATOR_PODS_READY" = false ]; then
    echo ""
    echo "Warning: Operator pods are not ready after ${MAX_WAIT_PODS} seconds"
    echo ""
    echo "=== Diagnostic Information ==="
    echo ""
    echo "1. Operator pods status:"
    oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator 2>/dev/null || echo "  No operator pods found"
    echo ""
    
    echo "2. Operator deployment status:"
    oc get deployment -n openshift-operators -l name=trusted-artifact-signer-operator -o yaml 2>/dev/null | grep -A 10 "status:" || echo "  No deployment found"
    echo ""
    
    echo "3. ReplicaSet status:"
    oc get replicaset -n openshift-operators -l name=trusted-artifact-signer-operator 2>/dev/null || echo "  No replicasets found"
    echo ""
    
    echo "4. CSV status and conditions:"
    oc get csv $CSV_NAME -n openshift-operators -o yaml 2>/dev/null | grep -A 20 "status:" | head -30 || echo "  Could not retrieve CSV status"
    echo ""
    
    echo "5. Recent events related to operator:"
    oc get events -n openshift-operators --field-selector involvedObject.name=$CSV_NAME --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -10 || echo "  No recent events found"
    echo ""
    
    echo "6. All pods in openshift-operators namespace (for context):"
    oc get pods -n openshift-operators --no-headers 2>/dev/null | grep -i "trusted\|rhtas" || echo "  No RHTAS-related pods found"
    echo ""
    
    echo "=== Troubleshooting Commands ==="
    echo ""
    echo "To investigate further, run:"
    echo "  oc describe csv $CSV_NAME -n openshift-operators"
    echo "  oc get deployment -n openshift-operators -l name=trusted-artifact-signer-operator -o yaml"
    echo "  oc get events -n openshift-operators --sort-by='.lastTimestamp' | grep -i 'trusted\|rhtas' | tail -20"
    echo "  oc logs -n openshift-operators -l name=trusted-artifact-signer-operator --tail=50"
    echo ""
    echo "This may cause issues when deploying RHTAS components. Continuing anyway..."
fi

fi

echo ""
echo "✓ RHTAS Operator installation completed"
echo "  CSV: $CSV_NAME"
echo "  Phase: $(oc get csv $CSV_NAME -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo 'Unknown')"
echo "  CRDs: Installed"
echo "  Operator Pods: $(oc get pods -n openshift-operators -l name=trusted-artifact-signer-operator --no-headers 2>/dev/null | wc -l || echo '0') running"
