#!/bin/bash
# Install the RHACS OpenShift Console plugin used by this lab (RHACS 4.10 SecuredCluster).
# Deletes leftover ACS ConsolePlugin CRs (including incomplete applies), then applies the
# canonical plugin that fronts sensor-proxy /proxy/central/static/ocp-plugin and enables it.
#
# Sourced by 06-configure-rhacs-settings.sh, or run standalone (e.g. after Central restarts).

ensure_rhacs_console_plugin() {
    _log() {
        if declare -F log >/dev/null 2>&1; then
            log "$1"
        else
            echo "[RHACS-CONSOLE-PLUGIN] $1"
        fi
    }
    _warn() {
        if declare -F warning >/dev/null 2>&1; then
            warning "$1"
        elif declare -F warn >/dev/null 2>&1; then
            warn "$1"
        else
            echo "[RHACS-CONSOLE-PLUGIN] WARN: $1" >&2
        fi
    }

    local plugin_name="advanced-cluster-security"
    local plugin_ns=""
    local ns
    local waited=0
    local max_wait="${RHACS_CONSOLE_PLUGIN_WAIT_SEC:-180}"
    local current_json=""
    local stripped_json=""
    local enabled_json=""
    local base_path=""

    _log "Installing RHACS OpenShift Console plugin (${plugin_name})..."

    if ! oc get consoles.operator.openshift.io cluster >/dev/null 2>&1; then
        _warn "Console operator resource not found; skipping RHACS console plugin"
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _warn "jq is required to enable the console plugin"
        return 1
    fi

    for ns in ${RHACS_NAMESPACE:-} stackrox rhacs-operator; do
        [ -z "$ns" ] && continue
        if oc get svc sensor-proxy -n "$ns" >/dev/null 2>&1; then
            plugin_ns="$ns"
            break
        fi
    done

    if [ -z "$plugin_ns" ]; then
        _log "Waiting up to ${max_wait}s for service/sensor-proxy (plugin backend)..."
        while [ "$waited" -lt "$max_wait" ]; do
            for ns in stackrox rhacs-operator; do
                if oc get svc sensor-proxy -n "$ns" >/dev/null 2>&1; then
                    plugin_ns="$ns"
                    break 2
                fi
            done
            sleep 5
            waited=$((waited + 5))
        done
    fi

    if [ -z "$plugin_ns" ]; then
        _warn "service/sensor-proxy not found in stackrox or rhacs-operator; cannot install console plugin"
        return 1
    fi
    _log "✓ Plugin backend service: sensor-proxy in namespace ${plugin_ns}"

    current_json=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
    if [ -z "$current_json" ] || [ "$current_json" = "null" ]; then
        current_json="[]"
    fi
    stripped_json=$(echo "$current_json" | jq -c '
        map(select(. != "advanced-cluster-security" and . != "acs" and . != "rhacs"))
    ' 2>/dev/null || echo "$current_json")
    if [ -n "$stripped_json" ] && [ "$stripped_json" != "$current_json" ]; then
        oc patch consoles.operator.openshift.io cluster --type=merge \
            -p '{"spec":{"plugins":'"${stripped_json}"'}}' >/dev/null 2>&1 || true
    fi

    _log "Removing any existing ACS ConsolePlugin CRs..."
    oc delete consoleplugin advanced-cluster-security acs rhacs --ignore-not-found=true --wait=true >/dev/null

    _log "Applying canonical ConsolePlugin ${plugin_name}..."
    if ! oc apply -f - <<EOF
apiVersion: console.openshift.io/v1
kind: ConsolePlugin
metadata:
  name: ${plugin_name}
  annotations:
    email: support@stackrox.com
    owner: stackrox
  labels:
    app.kubernetes.io/name: stackrox
    app.kubernetes.io/part-of: stackrox-secured-cluster-services
spec:
  displayName: Red Hat Advanced Cluster Security for OpenShift
  backend:
    type: Service
    service:
      name: sensor-proxy
      namespace: ${plugin_ns}
      port: 443
      basePath: /proxy/central/static/ocp-plugin
  proxy:
  - alias: api-service
    authorization: UserToken
    endpoint:
      type: Service
      service:
        name: sensor-proxy
        namespace: ${plugin_ns}
        port: 443
EOF
    then
        _warn "Failed to apply ConsolePlugin ${plugin_name}"
        return 1
    fi

    waited=0
    while [ "$waited" -lt 60 ]; do
        base_path=$(oc get consoleplugin "$plugin_name" -o jsonpath='{.spec.backend.service.basePath}' 2>/dev/null || echo "")
        if [ "$base_path" = "/proxy/central/static/ocp-plugin" ]; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    if [ "$base_path" != "/proxy/central/static/ocp-plugin" ]; then
        _warn "ConsolePlugin ${plugin_name} did not report expected basePath"
        return 1
    fi
    _log "✓ ConsolePlugin ${plugin_name} is present (sensor-proxy.${plugin_ns} /proxy/central/static/ocp-plugin)"

    current_json=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
    if [ -z "$current_json" ] || [ "$current_json" = "null" ]; then
        current_json="[]"
    fi
    enabled_json=$(echo "$current_json" | jq --arg p "$plugin_name" -c '
        map(select(. != "acs" and . != "rhacs" and . != $p)) + [$p] | unique
    ' 2>/dev/null || echo "[\"${plugin_name}\"]")

    if oc patch consoles.operator.openshift.io cluster --type=merge \
        -p '{"spec":{"plugins":'"${enabled_json}"'}}' >/dev/null 2>&1; then
        _log "✓ RHACS console plugin '${plugin_name}' enabled in OpenShift Console"
    else
        _warn "Could not patch OpenShift Console plugins; cluster-admin may be required"
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    ensure_rhacs_console_plugin
fi
