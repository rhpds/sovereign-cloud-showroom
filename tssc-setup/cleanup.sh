#!/bin/bash
# Undo cluster resources created by tssc-setup/setup.sh (reverse order: deploy → RHTAS operator → Keycloak CRs).
# Does not remove podman/cosign/gitsign from the workstation unless --remove-local-tools is passed.
#
# Usage:
#   ./cleanup.sh --yes                    # non-interactive, default scope
#   ./cleanup.sh --help
#
# Optional:
#   --skip-deploy              Do not delete the trusted-artifact-signer stack / namespace
#   --skip-rhtas-operator      Do not remove the RHTAS OLM Subscription in openshift-operators
#   --skip-keycloak-resources  Do not delete KeycloakRealm / KeycloakClient / KeycloakUser CRs from 02-operator.sh
#   --keycloak-namespace NS    Target namespace for Keycloak CR cleanup (default: auto-detect)
#   --rhtas-namespace NS       RHTAS deploy namespace (default: trusted-artifact-signer)
#   --delete-rhsso-namespace   Delete the entire rhsso namespace (RH-SSO operator + Keycloak from 01-keycloak.sh)
#   --delete-keycloak-namespace Delete the entire keycloak namespace (RHBK instance — very destructive)
#   --remove-rhsso-operator    Delete RH-SSO Subscription/CatalogSource/OperatorGroup in rhsso (keep namespace)
#   --remove-keycloak-operators Remove Keycloak operator OLM (rhsso + keycloak namespaces; opt-in)
#   --remove-local-tools       Best-effort: remove cosign-env.sh and cosign/gitsign from /usr/local/bin if present
# RHTAS: after Subscription delete, leftover CSVs in openshift-operators are force-removed so the operator UI clears.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-local-cluster}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[TSSC-CLEANUP]${NC} $1"; }
warn() { echo -e "${YELLOW}[TSSC-CLEANUP]${NC} $1"; }
err() { echo -e "${RED}[TSSC-CLEANUP]${NC} $1" >&2; }

YES=false
SKIP_DEPLOY=false
SKIP_RHTAS_OPERATOR=false
SKIP_KEYCLOAK_RESOURCES=false
DELETE_RHSSO_NS=false
DELETE_KEYCLOAK_NS=false
REMOVE_LOCAL_TOOLS=false
REMOVE_RHSSO_OPERATOR=false
REMOVE_KEYCLOAK_OPERATORS=false
RHTAS_NAMESPACE="${RHTAS_TARGET_NAMESPACE:-trusted-artifact-signer}"
KEYCLOAK_NS_ARG=""

usage() {
    cat <<'USAGE'
Undo tssc-setup cluster resources (reverse of setup.sh).

Usage: cleanup.sh [options]

  --yes, -y                 Do not prompt for confirmation
  --skip-deploy             Keep trusted-artifact-signer namespace and workloads
  --skip-rhtas-operator     Keep RHTAS Subscription/CSV in openshift-operators (default removes Sub + leftover CSVs)
  --skip-keycloak-resources Keep KeycloakRealm/Client/User CRs from 02-operator.sh
  --keycloak-namespace NS   Namespace for Keycloak CR cleanup (overrides auto-detect)
  --rhtas-namespace NS      RHTAS stack namespace (default: trusted-artifact-signer)
  --delete-rhsso-namespace  Delete entire rhsso namespace (RH-SSO path from 01-keycloak.sh)
  --delete-keycloak-namespace Delete entire keycloak namespace (RHBK — very destructive)
  --remove-rhsso-operator   Delete Subscription/CatalogSource/OperatorGroup in rhsso only (keep namespace)
  --remove-keycloak-operators  Remove Keycloak OLM (rhsso-operator stack and/or rhbk-operator in keycloak)
  --remove-local-tools      Remove cosign-env.sh and cosign/gitsign under /usr/local/bin if present

Environment (optional): KUBE_CONTEXT, KEYCLOAK_NAMESPACE_OVERRIDE, RHTAS_TARGET_NAMESPACE
USAGE
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) YES=true; shift ;;
        --skip-deploy) SKIP_DEPLOY=true; shift ;;
        --skip-rhtas-operator) SKIP_RHTAS_OPERATOR=true; shift ;;
        --skip-keycloak-resources) SKIP_KEYCLOAK_RESOURCES=true; shift ;;
        --delete-rhsso-namespace) DELETE_RHSSO_NS=true; shift ;;
        --delete-keycloak-namespace) DELETE_KEYCLOAK_NS=true; shift ;;
        --remove-rhsso-operator) REMOVE_RHSSO_OPERATOR=true; shift ;;
        --remove-keycloak-operators) REMOVE_KEYCLOAK_OPERATORS=true; shift ;;
        --remove-local-tools) REMOVE_LOCAL_TOOLS=true; shift ;;
        --rhtas-namespace) RHTAS_NAMESPACE="${2:?}"; shift 2 ;;
        --keycloak-namespace) KEYCLOAK_NS_ARG="${2:?}"; shift 2 ;;
        -h|--help) usage ;;
        *) err "Unknown option: $1"; echo "Use --help." >&2; exit 1 ;;
    esac
done

oc config use-context "$KUBE_CONTEXT" &>/dev/null || true

if ! oc whoami &>/dev/null; then
    err "Not logged in. Run: oc login"
    exit 1
fi

if [ "$YES" != true ]; then
    echo -e "${BLUE}This will remove TSSC-related OpenShift resources (see --help).${NC}"
    read -r -p "Continue? [y/N] " _a
    case "${_a:-}" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1 ;; esac
fi

# --- Keycloak namespace for CR cleanup (match discover_keycloak_namespace priority in 02-operator.sh) ---
discover_keycloak_namespace_for_cleanup() {
    local ns _csv_line _routes_out line _r_ns _r_name
    if [ -n "${KEYCLOAK_NS_ARG}" ]; then
        echo "${KEYCLOAK_NS_ARG}"
        return 0
    fi
    if [ -n "${KEYCLOAK_NAMESPACE_OVERRIDE:-}" ] && oc get namespace "${KEYCLOAK_NAMESPACE_OVERRIDE}" &>/dev/null; then
        echo "${KEYCLOAK_NAMESPACE_OVERRIDE}"
        return 0
    fi
    if [ -n "${KEYCLOAK_NAMESPACE:-}" ] && oc get namespace "${KEYCLOAK_NAMESPACE}" &>/dev/null; then
        echo "${KEYCLOAK_NAMESPACE}"
        return 0
    fi
    for ns in keycloak rhsso; do
        if oc get namespace "$ns" &>/dev/null; then
            if oc get keycloaks.k8s.keycloak.org -n "$ns" --no-headers 2>/dev/null | grep -q .; then echo "$ns"; return 0; fi
            if oc get keycloak.k8s.keycloak.org -n "$ns" --no-headers 2>/dev/null | grep -q .; then echo "$ns"; return 0; fi
            if oc get keycloakrealmimports.k8s.keycloak.org -n "$ns" --no-headers 2>/dev/null | grep -q .; then echo "$ns"; return 0; fi
            if oc get keycloaks.keycloak.org -n "$ns" --no-headers 2>/dev/null | grep -q .; then echo "$ns"; return 0; fi
            if oc get deployment -n "$ns" -l app.kubernetes.io/name=keycloak --no-headers 2>/dev/null | grep -q .; then echo "$ns"; return 0; fi
        fi
    done
    ns=$(oc get keycloaks.k8s.keycloak.org -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    [ -n "$ns" ] && echo "$ns" && return 0
    if oc get namespace keycloak &>/dev/null; then echo "keycloak"; return 0; fi
    if oc get namespace rhsso &>/dev/null; then echo "rhsso"; return 0; fi
    _routes_out=$(oc get routes -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        _r_ns="${line%% *}"
        _r_name="${line#* }"
        case "$_r_name" in keycloak-rhsso|keycloak|rhbk-keycloak|sso) echo "$_r_ns"; return 0 ;; esac
    done <<< "$_routes_out"
    return 1
}

OLM_SUB="subscription.operators.coreos.com"
OPERATOR_NS="openshift-operators"
CSV_API="clusterserviceversion.operators.coreos.com"

# Orphaned RHTAS OLM after Subscription delete (CSV / Operator API objects often linger).
rhtas_force_remove_olm_leavings() {
    local ns=$1 cname lc
    log "Removing leftover Trusted Artifact Signer / RHTAS CSVs in ${ns}..."
    while read -r cname _; do
        [ -z "$cname" ] && continue
        lc=$(echo "$cname" | tr '[:upper:]' '[:lower:]')
        case "$lc" in *rhtas*|*trusted-artifact-signer*)
            log "  deleting ${CSV_API}/${cname}"
            oc delete "${CSV_API}/$cname" -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true
            ;;
        esac
    done < <(oc get csv -n "$ns" --no-headers 2>/dev/null || true)

    if oc get crd operators.operators.coreos.com &>/dev/null; then
        while read -r oname _; do
            [ -z "$oname" ] && continue
            lc=$(echo "$oname" | tr '[:upper:]' '[:lower:]')
            case "$lc" in *rhtas*|*trusted-artifact*)
                log "  deleting operators.operators.coreos.com/${oname}"
                oc delete "operators.operators.coreos.com/$oname" -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true
                ;;
            esac
        done < <(oc get operators.operators.coreos.com -n "$ns" --no-headers 2>/dev/null || true)
    fi
}

# Keycloak operators installed by this lab (01-keycloak rhsso path; common RHBK subscription in keycloak).
remove_keycloak_operator_olm() {
    local cname lc
    if oc get namespace rhsso &>/dev/null; then
        log "Removing RH-SSO Keycloak operator OLM in rhsso (Subscription, CSV, CatalogSource, OperatorGroup)..."
        oc delete "${OLM_SUB}" rhsso-operator -n rhsso --ignore-not-found --wait=false 2>/dev/null || true
        while read -r cname _; do
            [ -z "$cname" ] && continue
            lc=$(echo "$cname" | tr '[:upper:]' '[:lower:]')
            case "$lc" in *rhsso*)
                oc delete "${CSV_API}/$cname" -n rhsso --ignore-not-found --wait=false 2>/dev/null || true
                ;;
            esac
        done < <(oc get csv -n rhsso --no-headers 2>/dev/null || true)
        oc delete catalogsource rhsso-operator-catalogsource -n rhsso --ignore-not-found --wait=false 2>/dev/null || true
        oc delete operatorgroup rhsso-operator-group -n rhsso --ignore-not-found --wait=false 2>/dev/null || true
    fi
    if oc get namespace keycloak &>/dev/null; then
        log "Removing Red Hat build of Keycloak operator OLM in keycloak (Subscription + matching CSVs)..."
        for _sub in rhbk-operator keycloak-operator; do
            oc delete "${OLM_SUB}" "$_sub" -n keycloak --ignore-not-found --wait=false 2>/dev/null || true
        done
        while read -r cname _; do
            [ -z "$cname" ] && continue
            lc=$(echo "$cname" | tr '[:upper:]' '[:lower:]')
            case "$lc" in *keycloak*|*rhbk*)
                oc delete "${CSV_API}/$cname" -n keycloak --ignore-not-found --wait=false 2>/dev/null || true
                ;;
            esac
        done < <(oc get csv -n keycloak --no-headers 2>/dev/null || true)
    fi
}

# --- 1) RHTAS workload namespace (03-deploy.sh) ---
if [ "$SKIP_DEPLOY" != true ]; then
    log "Removing RHTAS deploy namespace: ${RHTAS_NAMESPACE}"
    if oc get namespace "$RHTAS_NAMESPACE" &>/dev/null; then
        if oc get crd securesigns.rhtas.redhat.com &>/dev/null; then
            oc delete securesigns.rhtas.redhat.com --all -n "$RHTAS_NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
        fi
        for _rt in tufs.rhtas.redhat.com fulcios.rhtas.redhat.com rekors.rhtas.redhat.com; do
            oc delete "$_rt" --all -n "$RHTAS_NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
        done
        oc delete all --all -n "$RHTAS_NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
        oc delete pvc --all -n "$RHTAS_NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
        oc delete route --all -n "$RHTAS_NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
        if oc delete namespace "$RHTAS_NAMESPACE" --wait=false 2>/dev/null; then
            log "Namespace ${RHTAS_NAMESPACE} delete requested (may take a minute to terminate)."
        else
            warn "Could not delete namespace ${RHTAS_NAMESPACE} (permissions or already gone)."
        fi
    else
        log "Namespace ${RHTAS_NAMESPACE} not found — skipping."
    fi
else
    log "Skipping deploy / namespace (--skip-deploy)."
fi

# --- 2) RHTAS OLM Subscription (02-operator.sh) ---
if [ "$SKIP_RHTAS_OPERATOR" != true ]; then
    log "Removing RHTAS operator Subscription in ${OPERATOR_NS}..."
    if oc get "${OLM_SUB}" trusted-artifact-signer -n "$OPERATOR_NS" &>/dev/null; then
        oc delete "${OLM_SUB}" trusted-artifact-signer -n "$OPERATOR_NS" --ignore-not-found --wait=false 2>/dev/null || true
        log "Subscription trusted-artifact-signer removed (OLM will tear down the CSV when finished)."
    else
        log "No Subscription trusted-artifact-signer in ${OPERATOR_NS}."
    fi
    # Best-effort: stray subs named the same in other namespaces (from older scripts)
    while read -r ns name; do
        [ -z "$ns" ] && continue
        [ "$ns" = "$OPERATOR_NS" ] && continue
        warn "Deleting stray RHTAS subscription ${ns}/${name}"
        oc delete "${OLM_SUB}" "$name" -n "$ns" --ignore-not-found --wait=false 2>/dev/null || true
    done < <(oc get "${OLM_SUB}" -A --no-headers 2>/dev/null | awk '$2=="trusted-artifact-signer" {print $1, $2}' || true)
    rhtas_force_remove_olm_leavings "$OPERATOR_NS"
else
    log "Skipping RHTAS operator (--skip-rhtas-operator)."
fi

# --- 3) Keycloak CRs created by 02-operator.sh (order: users → clients → realm) ---
if [ "$SKIP_KEYCLOAK_RESOURCES" != true ]; then
    KEYCLOAK_CLEAN_NS=""
    if KEYCLOAK_CLEAN_NS=$(discover_keycloak_namespace_for_cleanup); then
        log "Cleaning Keycloak API objects in namespace: ${KEYCLOAK_CLEAN_NS}"
    else
        warn "Could not auto-detect Keycloak namespace; set KEYCLOAK_NAMESPACE_OVERRIDE or --keycloak-namespace. Skipping Keycloak CR cleanup."
        KEYCLOAK_CLEAN_NS=""
    fi
    if [ -n "$KEYCLOAK_CLEAN_NS" ] && oc get namespace "$KEYCLOAK_CLEAN_NS" &>/dev/null; then
        kc_delete_user() {
            local n=$1 u=$2
            oc delete "keycloakusers.k8s.keycloak.org/$u" -n "$n" --ignore-not-found --wait=false 2>/dev/null || true
            oc delete "keycloakusers.keycloak.org/$u" -n "$n" --ignore-not-found --wait=false 2>/dev/null || true
            oc delete "keycloakuser/$u" -n "$n" --ignore-not-found --wait=false 2>/dev/null || true
        }
        kc_delete_client() {
            local n=$1 c=$2
            oc delete "keycloakclients.k8s.keycloak.org/$c" -n "$n" --ignore-not-found --wait=false 2>/dev/null || true
            oc delete "keycloakclients.keycloak.org/$c" -n "$n" --ignore-not-found --wait=false 2>/dev/null || true
            oc delete "keycloakclient/$c" -n "$n" --ignore-not-found --wait=false 2>/dev/null || true
        }
        for u in jdoe user1 admin; do kc_delete_user "$KEYCLOAK_CLEAN_NS" "$u"; done
        kc_delete_client "$KEYCLOAK_CLEAN_NS" "trusted-artifact-signer"
        kc_delete_client "$KEYCLOAK_CLEAN_NS" "openshift"
        oc delete "keycloakrealms.k8s.keycloak.org/openshift" -n "$KEYCLOAK_CLEAN_NS" --ignore-not-found --wait=false 2>/dev/null || true
        oc delete "keycloakrealmimports.k8s.keycloak.org/openshift-realm-import" -n "$KEYCLOAK_CLEAN_NS" --ignore-not-found --wait=false 2>/dev/null || true
        oc delete "keycloakrealms.keycloak.org/openshift" -n "$KEYCLOAK_CLEAN_NS" --ignore-not-found --wait=false 2>/dev/null || true
        oc delete "keycloakrealm/openshift" -n "$KEYCLOAK_CLEAN_NS" --ignore-not-found --wait=false 2>/dev/null || true
        oc delete secret keycloak-client-secret-trusted-artifact-signer -n "$KEYCLOAK_CLEAN_NS" --ignore-not-found --wait=false 2>/dev/null || true
        oc delete secret keycloak-client-secret-openshift -n "$KEYCLOAK_CLEAN_NS" --ignore-not-found --wait=false 2>/dev/null || true
        log "KeycloakRealm/Client/User deletes issued for ${KEYCLOAK_CLEAN_NS}."
    fi
else
    log "Skipping Keycloak CR cleanup (--skip-keycloak-resources)."
fi

# --- 4) Optional: full namespace teardown (01-keycloak.sh paths) ---
if [ "$DELETE_RHSSO_NS" = true ]; then
    log "Deleting namespace rhsso (RH-SSO operator + Keycloak instance)..."
    oc delete namespace rhsso --ignore-not-found --wait=false 2>/dev/null || true
fi

if [ "$DELETE_KEYCLOAK_NS" = true ]; then
    log "Deleting namespace keycloak (Red Hat build of Keycloak — entire instance)..."
    oc delete namespace keycloak --ignore-not-found --wait=false 2>/dev/null || true
fi

# --- 5) Optional: RH-SSO operator resources without deleting namespace ---
if [ "$DELETE_RHSSO_NS" != true ] && [ "$REMOVE_RHSSO_OPERATOR" = true ] && [ "$REMOVE_KEYCLOAK_OPERATORS" != true ]; then
    log "Removing Subscription/CatalogSource/OperatorGroup in rhsso (namespace retained)."
    oc delete "${OLM_SUB}" rhsso-operator -n rhsso --ignore-not-found --wait=false 2>/dev/null || true
    oc delete catalogsource rhsso-operator-catalogsource -n rhsso --ignore-not-found --wait=false 2>/dev/null || true
    oc delete operatorgroup rhsso-operator-group -n rhsso --ignore-not-found --wait=false 2>/dev/null || true
fi

# --- 5b) Optional: remove Keycloak operator installs (RH-SSO + RHBK OLM) ---
if [ "$REMOVE_KEYCLOAK_OPERATORS" = true ]; then
    remove_keycloak_operator_olm
fi

# --- 6) Generated repo file ---
if [ -f "${SCRIPT_DIR}/cosign-env.sh" ]; then
    rm -f "${SCRIPT_DIR}/cosign-env.sh"
    log "Removed ${SCRIPT_DIR}/cosign-env.sh"
fi

# --- 7) Optional local CLIs ---
if [ "$REMOVE_LOCAL_TOOLS" = true ]; then
    warn "Removing cosign/gitsign from PATH (if installed to /usr/local/bin)..."
    for b in cosign gitsign; do
        if [ -w /usr/local/bin ] 2>/dev/null; then
            rm -f "/usr/local/bin/$b" 2>/dev/null || true
        else
            sudo rm -f "/usr/local/bin/$b" 2>/dev/null || true
        fi
    done
fi

log "Cleanup finished."
log "If the RHTAS or Keycloak operator still appears in Operators: re-run with --remove-keycloak-operators (Keycloak OLM) and ensure section 2 ran (no --skip-rhtas-operator)."
log "If a namespace is stuck Terminating: oc get namespace <name> -o yaml | check finalizers"
log "Re-install: ${SCRIPT_DIR}/setup.sh"
