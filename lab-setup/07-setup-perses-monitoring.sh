#!/bin/bash
#
# Lab step 06 — RHACS monitoring (certificates, COO/Perses stack, RHACS auth).
# YAMLs: lab-setup/monitoring-setup/{cluster-observability-operator,prometheus-operator,perses,rhacs}/
# Certs and .env.certs are written under lab-setup/ (this script's directory).
#
# Requires: oc, openssl, curl, envsubst; ROX_CENTRAL_ADDRESS and ROX_API_TOKEN (e.g. ~/.bashrc).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="$SCRIPT_DIR/monitoring-setup"
cd "$SCRIPT_DIR"

if [[ ! -d "$MONITORING_DIR" ]]; then
  echo "[ERROR] monitoring-setup not found: $MONITORING_DIR" >&2
  exit 1
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Strip https:// from ROX_CENTRAL_ADDRESS for tools that expect host:port (e.g. roxctl -e).
get_rox_endpoint() {
  local url="${ROX_CENTRAL_ADDRESS:-}"
  echo "${url#https://}"
}

load_rox_from_bashrc() {
  [[ ! -f ~/.bashrc ]] && return 0
  local var line
  for var in ROX_CENTRAL_ADDRESS ROX_API_TOKEN RHACS_NAMESPACE; do
    line=$(grep -E "^(export[[:space:]]+)?${var}=" ~/.bashrc 2>/dev/null | head -1) || true
    [[ -z "$line" ]] && continue
    if grep -qE '\$\(|`' <<< "$line"; then
      warn "Skipping ${var} from ~/.bashrc (command substitution)"
      continue
    fi
    [[ "$line" =~ ^export[[:space:]]+ ]] || line="export $line"
    eval "$line" 2>/dev/null || true
  done
}

echo ""
echo "=============================================="
echo "  RHACS Monitoring Setup"
echo "=============================================="
echo ""
log "Starting installation..."
echo ""
load_rox_from_bashrc
MISSING_VARS=0
if [[ -z "${ROX_CENTRAL_ADDRESS:-}" ]]; then error "ROX_CENTRAL_ADDRESS is not set"; MISSING_VARS=$((MISSING_VARS + 1)); fi
if [[ -z "${ROX_API_TOKEN:-}" ]]; then error "ROX_API_TOKEN is not set"; MISSING_VARS=$((MISSING_VARS + 1)); fi
if [[ $MISSING_VARS -gt 0 ]]; then
  echo ""
  error "Missing required environment variables. Set them or add to ~/.bashrc, then re-run:"
  echo "  bash \"$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")\""
  exit 1
fi
log "✓ Required environment variables are set"
echo ""

step "Step 1 of 3: Setting up certificates"
echo "=========================================="
echo ""

step "Certificate Generation"
echo "=========================================="
echo ""

log "Generating CA and client certificates in $SCRIPT_DIR..."

# Clean up any existing certificates
rm -f ca.key ca.crt ca.srl client.key client.crt client.csr

# Step 1: Create a proper CA (Certificate Authority)
log "Creating CA certificate..."
openssl genrsa -out ca.key 4096 2>/dev/null
openssl req -x509 -new -nodes -key ca.key -sha256 -days 1825 -out ca.crt \
  -subj "/CN=Monitoring Root CA/O=RHACS Demo" \
  -addext "basicConstraints=CA:TRUE" 2>/dev/null

# Step 2: Generate client certificate signed by the CA
log "Creating client certificate..."
openssl genrsa -out client.key 2048 2>/dev/null
openssl req -new -key client.key -out client.csr \
  -subj "/CN=monitoring-user/O=Monitoring Team" 2>/dev/null

# Sign the client cert with the CA and add clientAuth extended key usage
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 365 -sha256 \
  -extfile <(printf "extendedKeyUsage=clientAuth") 2>/dev/null

# Clean up intermediate files
rm -f client.csr ca.srl

# Create TLS secret for Prometheus using the client certificate
log "Creating Kubernetes secret for Prometheus..."
oc delete secret sample-stackrox-prometheus-tls -n stackrox 2>/dev/null || true
oc create secret tls sample-stackrox-prometheus-tls --cert=client.crt --key=client.key -n stackrox

# Export the CA certificate for the auth provider (this is what goes in the userpki config)
# The auth provider trusts certificates signed by this CA
export TLS_CERT=$(awk '{printf "%s\\n", $0}' ca.crt)

log "✓ Certificates generated successfully"
echo "  CA: $(openssl x509 -in ca.crt -noout -subject -dates | head -1)"
echo "  Client: $(openssl x509 -in client.crt -noout -subject -dates | head -1)"
echo ""

# Export TLS_CERT for parent script
echo "export TLS_CERT='$TLS_CERT'" > "$SCRIPT_DIR/.env.certs"
log "✓ Certificate environment exported to .env.certs"
echo ""

if [[ -f "$SCRIPT_DIR/.env.certs" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/.env.certs"
fi

step "Step 2 of 3: Installing monitoring stack"
echo ""

RHACS_NS="${RHACS_NS:-stackrox}"
MONITORING_STACK_NAME="${MONITORING_STACK_NAME:-sample-stackrox-monitoring-stack}"
SCRAPE_CONFIG_NAME="${SCRAPE_CONFIG_NAME:-sample-stackrox-scrape-config}"
# Default COO name; many clusters use a different STS name — see discover_prometheus_rollout_target()
DEFAULT_PROMETHEUS_STS_NAME="${MONITORING_STACK_NAME}-prometheus"
MONITORING_STACK_YAML="$MONITORING_DIR/cluster-observability-operator/monitoring-stack.yaml"
SCRAPE_CONFIG_YAML="$MONITORING_DIR/cluster-observability-operator/scrape-config.yaml"
COO_OPERATOR_NS="${COO_OPERATOR_NS:-openshift-cluster-observability-operator}"

# Poll until `oc get …` succeeds (API has the object).
wait_oc_get() {
  local timeout_sec="$1"
  shift
  local elapsed=0
  local step="${MONITORING_VERIFY_POLL_SEC:-5}"
  while [ "${elapsed}" -lt "${timeout_sec}" ]; do
    if oc get "$@" &>/dev/null; then
      return 0
    fi
    sleep "${step}"
    elapsed=$((elapsed + step))
  done
  return 1
}

# Re-apply YAML on repeated apply failures (webhook not ready, transient errors).
apply_file_retry() {
  local yamlf="$1"
  local desc="$2"
  local attempts="${MONITORING_PERSES_APPLY_RETRIES:-5}"
  local delay="${MONITORING_PERSES_APPLY_RETRY_DELAY:-20}"
  local attempt out
  for attempt in $(seq 1 "${attempts}"); do
    if out=$(oc apply -f "${yamlf}" 2>&1); then
      echo "${out}"
      return 0
    fi
    echo "${out}" >&2
    if [ "${attempt}" -lt "${attempts}" ]; then
      warn "${desc} apply failed — retry in ${delay}s (${attempt}/${attempts})"
      sleep "${delay}"
    else
      return 1
    fi
  done
  return 1
}

# After a successful apply, wait until the object is visible; once re-apply + wait if needed.
verify_after_apply() {
  local timeout="$1"
  local yamlf="$2"
  shift 2
  if wait_oc_get "${timeout}" "$@"; then
    return 0
  fi
  warn "Resource not visible after apply — re-applying $(basename "${yamlf}") and waiting again..."
  oc apply -f "${yamlf}"
  sleep "${MONITORING_REAPPLY_SETTLE_SEC:-10}"
  if wait_oc_get "${timeout}" "$@"; then
    return 0
  fi
  return 1
}

wait_for_coo_csv_succeeded() {
  local ns="${COO_OPERATOR_NS}"
  local max_wait="${COO_CSV_WAIT_SEC:-600}"
  local elapsed=0
  local step=15
  local phase=""
  local name=""

  log "Waiting for Cluster Observability Operator CSV (Succeeded)..."
  while [ "${elapsed}" -lt "${max_wait}" ]; do
    name=$(oc get csv -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Ei 'cluster-observability' | head -1 || true)
    if [ -n "${name}" ]; then
      phase=$(oc get csv "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [ "${phase}" = "Succeeded" ]; then
        log "✓ Cluster Observability Operator ready (${name})"
        return 0
      fi
      log "  COO CSV: ${name} phase=${phase} (${elapsed}s / ${max_wait}s)"
    else
      log "  Waiting for COO CSV to appear (${elapsed}s / ${max_wait}s)..."
    fi
    sleep "${step}"
    elapsed=$((elapsed + step))
  done
  warn "COO CSV not Succeeded within ${max_wait}s — check: oc get csv -n ${ns}; continuing (MonitoringStack loop may still wait on CRDs)"
  return 0
}

# Discover workload for `oc rollout status`: explicit PROMETHEUS_ROLLOUT_TARGET, or
# default STS name, or any STS/Deploy whose name matches this MonitoringStack / prometheus.
# Prints one line: statefulset/foo or deployment/bar
discover_prometheus_rollout_target() {
  local ns="$1"
  local ms_name="$2"
  local line

  if [ -n "${PROMETHEUS_ROLLOUT_TARGET:-}" ]; then
    echo "${PROMETHEUS_ROLLOUT_TARGET}"
    return 0
  fi

  if oc get "statefulset/${DEFAULT_PROMETHEUS_STS_NAME}" -n "${ns}" &>/dev/null; then
    echo "statefulset/${DEFAULT_PROMETHEUS_STS_NAME}"
    return 0
  fi

  # Prefer STS tied to this MonitoringStack (name contains CR name + prometheus)
  line=$(oc get sts -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -F "${ms_name}" | grep -i prometheus | head -1)
  if [ -n "${line}" ]; then
    echo "statefulset/${line}"
    return 0
  fi

  # Any Prometheus StatefulSet in namespace (COO naming varies by version)
  line=$(oc get sts -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i prometheus | head -1)
  if [ -n "${line}" ]; then
    echo "statefulset/${line}"
    return 0
  fi

  line=$(oc get deploy -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -iE "prometheus.*${ms_name}|${ms_name}.*prometheus|sample-stackrox.*prometheus" | head -1)
  if [ -n "${line}" ]; then
    echo "deployment/${line}"
    return 0
  fi

  return 1
}

# Wait for Ready pods carrying the standard Prometheus label (works when rollout target name differs).
wait_prometheus_pods_ready() {
  local ns="$1"
  local timeout_sec="${2:-120}"
  if ! oc get pods -n "${ns}" -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | grep -q .; then
    return 1
  fi
  oc wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n "${ns}" --timeout="${timeout_sec}s" 2>/dev/null
}

# True if Prometheus is already serving: Service has endpoints, or any *prometheus* pod is Ready (COO label/name varies).
prometheus_stack_observable() {
  local ns="$1"
  local svc="${MONITORING_STACK_NAME}-prometheus"
  local addr pod r

  if oc get "svc/${svc}" -n "${ns}" &>/dev/null; then
    addr=$(oc get endpoints "${svc}" -n "${ns}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
    if [ -n "${addr}" ]; then
      return 0
    fi
    addr=$(oc get endpointslice -n "${ns}" -l "kubernetes.io/service-name=${svc}" -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null || true)
    if [ -n "${addr}" ]; then
      return 0
    fi
  fi

  while IFS= read -r pod; do
    [ -z "${pod}" ] && continue
    r=$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "${r}" = "True" ]; then
      return 0
    fi
  done < <(oc get pods -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i prometheus || true)

  return 1
}

# Wait for operator Prometheus workload: discovered STS/Deploy rollout, else pod readiness.
wait_for_coo_prometheus_ready() {
  local attempt_label="$1"
  local max_wait="${COO_PROMETHEUS_WAIT_SEC:-300}"
  local elapsed=0
  local step_wait=10
  local target

  if prometheus_stack_observable "${RHACS_NS}"; then
    log "✓ Prometheus already operational (Service endpoints or Ready *prometheus* pod) — ${attempt_label}"
    return 0
  fi

  while [ "${elapsed}" -lt "${max_wait}" ]; do
    if prometheus_stack_observable "${RHACS_NS}"; then
      log "✓ Prometheus became operational — ${attempt_label}"
      return 0
    fi
    if target=$(discover_prometheus_rollout_target "${RHACS_NS}" "${MONITORING_STACK_NAME}"); then
      log "✓ Prometheus workload found: ${target} (${attempt_label})"
      if oc rollout status "${target}" -n "${RHACS_NS}" --timeout=240s; then
        log "✓ Rollout complete (${target})"
        return 0
      fi
      warn "rollout not finished for ${target} — checking pod readiness..."
      if wait_prometheus_pods_ready "${RHACS_NS}" 120; then
        log "✓ Prometheus pod(s) Ready (workload: ${target})"
        return 0
      fi
    fi

    if wait_prometheus_pods_ready "${RHACS_NS}" 45; then
      log "✓ Prometheus pod(s) Ready via label app.kubernetes.io/name=prometheus (${attempt_label})"
      return 0
    fi

    log "  Waiting for Prometheus workload or pods... (${elapsed}s/${max_wait}s)"
    sleep "${step_wait}"
    elapsed=$((elapsed + step_wait))
  done
  return 1
}

verify_scrape_config_present() {
  if oc get scrapeconfig "${SCRAPE_CONFIG_NAME}" -n "${RHACS_NS}" &>/dev/null; then
    log "✓ ScrapeConfig ${SCRAPE_CONFIG_NAME} present in ${RHACS_NS}"
    return 0
  fi
  return 1
}

verify_monitoring_stack_cr() {
  if oc get monitoringstack "${MONITORING_STACK_NAME}" -n "${RHACS_NS}" &>/dev/null; then
    log "✓ MonitoringStack CR ${MONITORING_STACK_NAME} present in ${RHACS_NS}"
    return 0
  fi
  return 1
}

# After applies: confirm CRs exist, Prometheus is ready; optionally re-apply once on failure.
verify_and_finalize_coo_stack() {
  echo ""
  step "Verifying Cluster Observability stack (MonitoringStack / ScrapeConfig / Prometheus)"
  echo ""

  if ! verify_monitoring_stack_cr; then
    error "MonitoringStack CR missing — apply may have failed silently"
    return 1
  fi

  if ! verify_scrape_config_present; then
    warn "ScrapeConfig not found — re-applying ${SCRAPE_CONFIG_YAML}..."
    oc apply -f "${SCRAPE_CONFIG_YAML}"
    sleep 5
    if ! verify_scrape_config_present; then
      error "ScrapeConfig ${SCRAPE_CONFIG_NAME} still missing after re-apply"
      return 1
    fi
  fi

  if [ "${MONITORING_SKIP_PROMETHEUS_READY_WAIT:-0}" = "1" ]; then
    warn "Skipping Prometheus readiness wait (MONITORING_SKIP_PROMETHEUS_READY_WAIT=1) — CRs only"
    return 0
  fi

  if wait_for_coo_prometheus_ready "attempt 1"; then
    return 0
  fi

  warn "Prometheus StatefulSet not ready on first wait — re-applying stack + scrape, then retrying..."
  oc apply -f "${MONITORING_STACK_YAML}"
  oc apply -f "${SCRAPE_CONFIG_YAML}"
  sleep 15

  if wait_for_coo_prometheus_ready "attempt 2 (after re-apply)"; then
    return 0
  fi

  error "Prometheus did not become ready — check: oc get sts,deploy,pod -n ${RHACS_NS} | grep -i prometheus; oc describe monitoringstack ${MONITORING_STACK_NAME} -n ${RHACS_NS}; optional: export PROMETHEUS_ROLLOUT_TARGET=statefulset/<name>"
  return 1
}

step "Monitoring Stack Installation"
echo "=========================================="
echo ""

# Ensure we're in the stackrox namespace
log "Switching to stackrox namespace..."
oc project stackrox

# Per RHACS 4.10 docs 15.2.1: Disable OpenShift monitoring when using custom Prometheus
# https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.10/html/configuring/monitor-acs
CENTRAL_CR=$(oc get central -n stackrox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$CENTRAL_CR" ]; then
  log "Disabling OpenShift monitoring on Central (required for custom Prometheus)..."
  if oc patch central "$CENTRAL_CR" -n stackrox --type=merge -p='{"spec":{"monitoring":{"openshift":{"enabled":false}}}}' 2>/dev/null; then
    log "✓ OpenShift monitoring disabled"
  elif oc patch central "$CENTRAL_CR" -n stackrox --type=merge -p='{"spec":{"central":{"monitoring":{"openshift":{"enabled":false}}}}}' 2>/dev/null; then
    log "✓ OpenShift monitoring disabled"
  else
    warn "Could not patch Central CR - ensure monitoring.openshift.enabled: false is set manually"
  fi
else
  warn "Central CR not found - skip disabling OpenShift monitoring (Helm/other install)"
fi

echo ""
log "Installing Cluster Observability Operator..."
oc apply -f "$MONITORING_DIR/cluster-observability-operator/subscription.yaml"
log "✓ Cluster Observability Operator subscription created"

wait_for_coo_csv_succeeded

echo ""
log "Installing and configuring monitoring stack instance..."
max_wait=300
elapsed=0
while [ $elapsed -lt $max_wait ]; do
  if out=$(oc apply -f "$MONITORING_STACK_YAML" 2>&1); then
    echo "$out"
    log "✓ MonitoringStack applied"
    break
  fi
  if echo "$out" | grep -qE "no matches for kind \"MonitoringStack\"|ensure CRDs are installed first"; then
    log "  Waiting for operator CRDs... (${elapsed}s/${max_wait}s)"
    sleep 15
    elapsed=$((elapsed + 15))
  else
    echo "$out" >&2
    exit 1
  fi
done
if [ $elapsed -ge $max_wait ]; then
  error "MonitoringStack apply failed after ${max_wait}s - operator may not be ready"
  exit 1
fi

if out=$(oc apply -f "$SCRAPE_CONFIG_YAML" 2>&1); then
  echo "$out"
  log "✓ ScrapeConfig applied"
else
  echo "$out" >&2
  error "ScrapeConfig apply failed"
  exit 1
fi

if ! verify_and_finalize_coo_stack; then
  exit 1
fi

echo ""
log "Installing Prometheus Operator resources (for clusters with Prometheus Operator)..."
if oc get crd prometheuses.monitoring.coreos.com &>/dev/null; then
  PROM_OP_PROM_YAML="$MONITORING_DIR/prometheus-operator/prometheus.yaml"
  oc apply -f "$MONITORING_DIR/prometheus-operator/"
  log "✓ Prometheus Operator resources applied"
  if wait_oc_get "${MONITORING_PROMETHEUS_CR_WAIT_SEC:-120}" -f "${PROM_OP_PROM_YAML}"; then
    log "✓ Prometheus Operator CR visible (sample-stackrox-prometheus-server)"
  else
    warn "Prometheus CR not visible yet — COO Prometheus may still be used for metrics"
  fi
else
  log "Prometheus Operator CRD not found - skipping"
fi

echo ""
log "Installing Perses and configuring the RHACS dashboard..."
sleep "${MONITORING_PRE_PERSES_SLEEP_SEC:-15}"

VERIFY_SEC="${MONITORING_RESOURCE_VERIFY_SEC:-180}"
UI_PLUGIN_YAML="$MONITORING_DIR/perses/ui-plugin.yaml"
DATASOURCE_YAML="$MONITORING_DIR/perses/datasource.yaml"
DASHBOARD_YAML="$MONITORING_DIR/perses/dashboard.yaml"

if ! apply_file_retry "${UI_PLUGIN_YAML}" "UIPlugin (monitoring)"; then
  error "UIPlugin apply failed"
  exit 1
fi
log "✓ Perses UI Plugin applied"
if ! verify_after_apply "${VERIFY_SEC}" "${UI_PLUGIN_YAML}" -f "${UI_PLUGIN_YAML}"; then
  error "UIPlugin not visible in API after apply — check observability / console operator"
  exit 1
fi
log "✓ Perses UI Plugin confirmed in cluster"

if ! apply_file_retry "${DATASOURCE_YAML}" "PersesDatasource (sample-stackrox-datasource)"; then
  error "PersesDatasource apply failed"
  exit 1
fi
log "✓ Perses Datasource applied"
if ! verify_after_apply "${VERIFY_SEC}" "${DATASOURCE_YAML}" -f "${DATASOURCE_YAML}"; then
  error "PersesDatasource not visible after apply — check Perses operator webhooks"
  exit 1
fi
log "✓ Perses Datasource confirmed in cluster"

log "Creating Perses Dashboard..."
if ! apply_file_retry "${DASHBOARD_YAML}" "PersesDashboard (sample-stackrox-dashboard)"; then
  error "Perses Dashboard creation failed"
  exit 1
fi
log "✓ Perses Dashboard applied"
if ! verify_after_apply "${VERIFY_SEC}" "${DASHBOARD_YAML}" -f "${DASHBOARD_YAML}"; then
  error "PersesDashboard not visible after apply"
  exit 1
fi
log "✓ Perses Dashboard confirmed in cluster"

echo ""
log "✓ Monitoring stack installation complete"
echo ""

is_role_not_ready_error() {
  echo "$1" | grep -qiE 'role.*(does not exist|not found)|unknown role|invalid role|no role named|could not find role|cannot find role|invalid.*roleName|roleName.*(invalid|unknown)'
}

# Poll until GET /v1/roles includes "Prometheus Server" (declarative config processed)
wait_for_prometheus_server_role() {
  local max_s="${1:-600}"
  local slept=0
  local interval=15
  log "Waiting for declarative role 'Prometheus Server' in RHACS API (GET /v1/roles, up to ${max_s}s)..."
  while [ "$slept" -lt "$max_s" ]; do
    local roles_json http_code
    roles_json=$(curl -k -s -w "\n%{http_code}" --max-time 30 \
      -H "Authorization: Bearer $ROX_API_TOKEN" \
      "$ROX_CENTRAL_ADDRESS/v1/roles" 2>/dev/null) || true
    http_code=$(echo "$roles_json" | tail -n1)
    roles_json=$(echo "$roles_json" | sed '$d')
    if ! echo "$http_code" | grep -qE '^2'; then
      warn "  /v1/roles HTTP ${http_code} — retrying..."
    elif command -v jq &>/dev/null; then
      if echo "$roles_json" | jq -e '.roles[]? | select(.name == "Prometheus Server")' &>/dev/null; then
        log "✓ Role 'Prometheus Server' is available"
        return 0
      fi
    elif echo "$roles_json" | grep -q '"name"[[:space:]]*:[[:space:]]*"Prometheus Server"'; then
      log "✓ Role 'Prometheus Server' is available (grep fallback)"
      return 0
    fi
    log "  Declarative role not visible yet... (${slept}s / ${max_s}s)"
    sleep "$interval"
    slept=$((slept + interval))
  done
  warn "Timed out waiting for 'Prometheus Server' role — proceeding with group POST retries only"
  return 1
}

# Strip last line (curl http_code); portable (no GNU head -n -1)
strip_curl_http_line() {
  sed '$d'
}

step "Step 3 of 3: Configuring RHACS authentication"
echo "=========================================="
echo ""

# Check required environment variables
if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
  error "ROX_CENTRAL_ADDRESS is not set"
  exit 1
fi

if [ -z "${ROX_API_TOKEN:-}" ]; then
  error "ROX_API_TOKEN is not set"
  exit 1
fi

# Load TLS_CERT from certificate generation script
if [ -f "$SCRIPT_DIR/.env.certs" ]; then
  source "$SCRIPT_DIR/.env.certs"
else
  warn ".env.certs not found, loading TLS_CERT from ca.crt..."
  if [ -f "$SCRIPT_DIR/ca.crt" ]; then
    export TLS_CERT=$(awk '{printf "%s\\n", $0}' ca.crt)
  else
    error "ca.crt not found. Re-run this script from the start (Step 1 creates certificates)."
    exit 1
  fi
fi

log "Declaring a permission set and a role in RHACS..."

# First, create the declarative configuration ConfigMap
oc apply -f "$MONITORING_DIR/rhacs/declarative-configuration-configmap.yaml"
log "✓ Declarative configuration ConfigMap created"

echo ""
log "Checking if declarative configuration is enabled on Central..."
if oc get deployment central -n stackrox -o yaml | grep -q "declarative-config"; then
  log "✓ Declarative configuration is already enabled"
else
  warn "Declarative configuration mount not found on Central deployment"
  log "Enabling declarative configuration on Central..."
  
  # Check if Central is managed by operator or deployed directly
  if oc get central stackrox-central-services -n stackrox &>/dev/null; then
    log "Using RHACS Operator to enable declarative configuration..."
    oc patch central stackrox-central-services -n stackrox --type=merge -p='
spec:
  central:
    declarativeConfiguration:
      configMaps:
      - name: sample-stackrox-prometheus-declarative-configuration
'
    log "Waiting for Central to update..."
    sleep 10
  else
    log "Directly patching Central deployment..."
    # For non-operator deployments, manually add volume and mount
    oc set volume deployment/central -n stackrox \
      --add --name=declarative-config \
      --type=configmap \
      --configmap-name=sample-stackrox-prometheus-declarative-configuration \
      --mount-path=/run/secrets/stackrox.io/declarative-config \
      --read-only=true
  fi
  
  log "Waiting for Central to restart..."
  oc rollout status deployment/central -n stackrox --timeout=300s
  log "✓ Declarative configuration enabled"
fi

# Give Central time to process declarative config (roles) after startup
log "Waiting for declarative config to be processed (30s)..."
sleep 30

# Wait for Central API to be ready (may take a moment after restart)
log "Checking Central API readiness..."
for i in $(seq 1 30); do
  if code=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "$ROX_CENTRAL_ADDRESS/v1/auth/status" -H "Authorization: Bearer $ROX_API_TOKEN") && echo "$code" | grep -qE "^[234][0-9]{2}$"; then
    log "Central API is ready"
    break
  fi
  [ $i -lt 30 ] && sleep 2
done

echo ""
log "Checking for existing 'Monitoring' auth provider..."

# Get all auth providers and extract the ID for "Monitoring"
if command -v jq &>/dev/null; then
  EXISTING_AUTH_ID=$(curl -k -s "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
    -H "Authorization: Bearer $ROX_API_TOKEN" | \
    jq -r '.authProviders[]? | select(.name=="Monitoring") | .id' 2>/dev/null) || EXISTING_AUTH_ID=""
else
  EXISTING_AUTH_ID=$(curl -k -s "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
    -H "Authorization: Bearer $ROX_API_TOKEN" | \
    grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4) || EXISTING_AUTH_ID=""
fi

# Delete if exists
if [ -n "$EXISTING_AUTH_ID" ] && [ "$EXISTING_AUTH_ID" != "null" ]; then
  log "Deleting existing 'Monitoring' auth provider (ID: $EXISTING_AUTH_ID)..."
  curl -k -s -X DELETE "$ROX_CENTRAL_ADDRESS/v1/authProviders/$EXISTING_AUTH_ID" \
    -H "Authorization: Bearer $ROX_API_TOKEN" > /dev/null
  log "✓ Deleted existing auth provider"
  sleep 2
fi

echo ""
log "Creating User-Certificate auth provider..."
# Central may need a moment after restart - retry auth provider creation if it fails
AUTH_PROVIDER_ID=""
max_auth_retries=4
auth_retry_delay=20
for auth_attempt in $(seq 1 $max_auth_retries); do
  AUTH_PROVIDER_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$(envsubst < "$MONITORING_DIR/rhacs/auth-provider.json.tpl")")

  HTTP_CODE=$(echo "$AUTH_PROVIDER_RESPONSE" | tail -1)
  AUTH_RESPONSE_BODY=$(echo "$AUTH_PROVIDER_RESPONSE" | strip_curl_http_line)

  # Extract the auth provider ID from the response (try multiple patterns)
  AUTH_PROVIDER_ID=$(echo "$AUTH_RESPONSE_BODY" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/' 2>/dev/null) || true

  if [ -z "$AUTH_PROVIDER_ID" ] && command -v jq &>/dev/null; then
    AUTH_PROVIDER_ID=$(echo "$AUTH_RESPONSE_BODY" | jq -r '.id // empty' 2>/dev/null)
  fi

  if [ -n "$AUTH_PROVIDER_ID" ] && [ "$AUTH_PROVIDER_ID" != "null" ]; then
    export AUTH_PROVIDER_ID
    break
  fi
  if [ $auth_attempt -lt $max_auth_retries ]; then
    warn "Auth provider creation failed or API not ready (HTTP $HTTP_CODE) - retrying in ${auth_retry_delay}s (attempt $auth_attempt/$max_auth_retries)..."
    [ -n "$AUTH_RESPONSE_BODY" ] && warn "Response: $AUTH_RESPONSE_BODY"
    sleep $auth_retry_delay
  else
    error "Failed to create auth provider after $max_auth_retries attempts"
    error "Last response (HTTP $HTTP_CODE): $AUTH_RESPONSE_BODY"
    exit 1
  fi
done

if [ -n "$AUTH_PROVIDER_ID" ]; then
  log "✓ Auth provider created with ID: $AUTH_PROVIDER_ID"
  
  # Wait a moment for auth provider to fully initialize
  sleep 2

  # Declarative roles can take minutes to appear after Central rollout; poll API before POST /groups
  wait_for_prometheus_server_role 600 || true
  
  # Create group mapping with Prometheus Server role (retry if role not yet available)
  log "Creating 'Prometheus Server' role group mapping..."
  GROUP_PAYLOAD=$(envsubst < "$MONITORING_DIR/rhacs/admin-group.json.tpl")
  log "Group payload: $GROUP_PAYLOAD"
  
  max_retries=15
  retry_delay=20
  group_created=false
  
  for attempt in $(seq 1 $max_retries); do
    GROUP_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST "$ROX_CENTRAL_ADDRESS/v1/groups" \
      -H "Authorization: Bearer $ROX_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data-raw "$GROUP_PAYLOAD")
    
    HTTP_CODE=$(echo "$GROUP_RESPONSE" | tail -1)
    RESPONSE_BODY=$(echo "$GROUP_RESPONSE" | strip_curl_http_line)
    
    if [ "$HTTP_CODE" = "200" ]; then
      if echo "$RESPONSE_BODY" | grep -q '"props"'; then
        log "✓ Group created successfully (HTTP $HTTP_CODE)"
        log "Role 'Prometheus Server' assigned to Monitoring auth provider"
      else
        log "✓ API returned success (HTTP $HTTP_CODE)"
      fi
      warn "Auth changes may take 10-30 seconds to propagate"
      group_created=true
      break
    elif [ "$HTTP_CODE" = "409" ]; then
      log "✓ Group already exists for Monitoring auth provider"
      group_created=true
      break
    elif echo "$HTTP_CODE" | grep -qE '^(502|503|504)$'; then
      if [ "$attempt" -lt "$max_retries" ]; then
        warn "Transient HTTP $HTTP_CODE from Central — retrying in ${retry_delay}s ($attempt/$max_retries)..."
        sleep "$retry_delay"
      else
        error "Group creation failed after retries (HTTP $HTTP_CODE)"
        error "Response: $RESPONSE_BODY"
        break
      fi
    elif is_role_not_ready_error "$RESPONSE_BODY"; then
      if [ "$attempt" -lt "$max_retries" ]; then
        warn "Role 'Prometheus Server' not yet accepted by API (declarative config still syncing)"
        log "  Retrying in ${retry_delay}s (attempt $attempt/$max_retries)..."
        sleep "$retry_delay"
      else
        error "Group creation failed (HTTP $HTTP_CODE) after $max_retries attempts"
        error "Response: $RESPONSE_BODY"
        break
      fi
    else
      error "Group creation failed (HTTP $HTTP_CODE)"
      error "Response: $RESPONSE_BODY"
      break
    fi
  done
  
  if [ "$group_created" != "true" ]; then
    echo ""
    warn "Attempting to verify if group exists..."
    EXISTING_GROUPS=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_ADDRESS/v1/groups" | \
      grep -A10 "$AUTH_PROVIDER_ID" 2>/dev/null) || EXISTING_GROUPS=""
    
    if [ -n "$EXISTING_GROUPS" ]; then
      log "✓ Found existing group for this auth provider"
    else
      error "No groups found for auth provider ID: $AUTH_PROVIDER_ID"
      error ""
      error "The 'Prometheus Server' role is defined in declarative config. Ensure:"
      error "1. Declarative config ConfigMap is applied and mounted on Central"
      error "2. Central has restarted to pick up the declarative config"
      error ""
      error "Manual fix required:"
      error "1. Via RHACS UI:"
      error "   Platform Configuration → Access Control → Groups → Create Group"
      error "   - Auth Provider: Monitoring"
      error "   - Key: (leave empty)"
      error "   - Value: (leave empty)"
      error "   - Role: Prometheus Server"
      error ""
      error "2. Via API:"
      error "   curl -k -X POST \"\$ROX_CENTRAL_ADDRESS/v1/groups\" \\"
      error "     -H \"Authorization: Bearer \$ROX_API_TOKEN\" \\"
      error "     -H \"Content-Type: application/json\" \\"
      error "     -d '{\"props\":{\"authProviderId\":\"$AUTH_PROVIDER_ID\",\"key\":\"\",\"value\":\"\"},\"roleName\":\"Prometheus Server\"}'"
      error ""
      error "3. Optional: rhacs-demo/monitoring-setup/troubleshoot-auth.sh for deeper diagnosis"
      exit 1
    fi
  fi
else
  error "Failed to extract auth provider ID from API response"
  error "API response: $AUTH_PROVIDER_RESPONSE"
  error "You may need to configure the group manually"
  exit 1
fi

echo ""
log "✓ RHACS authentication configuration complete"
echo ""

echo ""
echo "============================================"
echo "Verifying Configuration"
echo "============================================"
echo ""
# Non-login shells do not source ~/.bashrc; re-load for verification curl calls.
log "Loading ROX_CENTRAL_ADDRESS / ROX_API_TOKEN from ~/.bashrc before verification..."
load_rox_from_bashrc
if [ -n "${ROX_CENTRAL_ADDRESS:-}" ] && [ -n "${ROX_API_TOKEN:-}" ]; then
  export ROX_CENTRAL_ADDRESS ROX_API_TOKEN
fi

if [ -z "${ROX_CENTRAL_ADDRESS:-}" ] || [ -z "${ROX_API_TOKEN:-}" ]; then
  warn "Skipping API/metrics verification — ROX_CENTRAL_ADDRESS or ROX_API_TOKEN not set after reading ~/.bashrc."
  warn "Run: source ~/.bashrc   then export or re-run this script."
else
  # Give auth system time to propagate changes
  log "Waiting for auth configuration to propagate (10 seconds)..."
  sleep 10

# Extract auth provider ID if not already set earlier in this script
if [ -z "${AUTH_PROVIDER_ID:-}" ]; then
  # Try to get it from the API
  if command -v jq &>/dev/null; then
    AUTH_PROVIDER_ID=$(curl -k -s "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
      -H "Authorization: Bearer $ROX_API_TOKEN" | \
      jq -r '.authProviders[]? | select(.name=="Monitoring") | .id' 2>/dev/null)
  else
    AUTH_PROVIDER_ID=$(curl -k -s "$ROX_CENTRAL_ADDRESS/v1/authProviders" \
      -H "Authorization: Bearer $ROX_API_TOKEN" | \
      grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4)
  fi
fi

# Verify the group was created
log "Checking groups for auth provider..."
GROUPS_LIST=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_ADDRESS/v1/groups" | grep -A5 "$AUTH_PROVIDER_ID" || echo "")

if [ -n "$GROUPS_LIST" ]; then
  log "✓ Group mapping found for Monitoring auth provider"
  
  # Test client certificate authentication
  echo ""
  log "Testing client certificate authentication..."
  AUTH_TEST=$(curl -k -s --cert client.crt --key client.key "$ROX_CENTRAL_ADDRESS/v1/auth/status" 2>&1)
  
  if echo "$AUTH_TEST" | grep -q '"userId"'; then
    log "✓ Client certificate authentication successful!"
    
    # Also test metrics endpoint (disable set -e for this block - curl|head can cause SIGPIPE)
    echo ""
    log "Testing metrics endpoint access..."
    set +e
    METRICS_TEST=$(curl -k -s --max-time 30 --cert client.crt --key client.key "$ROX_CENTRAL_ADDRESS/metrics" 2>&1 | head -10)
    set -e

    if echo "$METRICS_TEST" | grep -q "access for this user is not authorized"; then
      error "✗ Metrics endpoint access denied: no valid role"
      echo ""
      error "The group mapping exists but the role assignment is incorrect."
      error "Check group role mapping and declarative config; see rhacs-demo/monitoring-setup/troubleshoot-auth.sh if needed."
    elif echo "$METRICS_TEST" | grep -q '^curl:'; then
      warn "Metrics curl failed (bad URL or network). Ensure ROX_CENTRAL_ADDRESS is set: source ~/.bashrc"
      echo "$METRICS_TEST"
    elif echo "$METRICS_TEST" | grep -q '^#'; then
      log "✓ Metrics endpoint access successful!"
    else
      warn "Metrics endpoint returned unexpected response (first 10 lines):"
      echo "$METRICS_TEST"
    fi
  elif echo "$AUTH_TEST" | grep -q "credentials not found"; then
    warn "Authentication failed: credentials not found"
    echo ""
    warn "This may take 10-30 seconds to propagate. Wait a moment and try:"
    echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_ADDRESS/v1/auth/status"
    echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_ADDRESS/metrics"
    echo ""
    warn "If it continues to fail, see rhacs-demo/monitoring-setup/troubleshoot-auth.sh for diagnosis."
  else
    warn "Unexpected response: $AUTH_TEST"
  fi
else
  warn "No group mapping found - authentication may fail!"
  echo ""
  warn "See rhacs-demo/monitoring-setup/troubleshoot-auth.sh if you need a guided diagnostic script."
fi

fi

#================================================================


echo ""
echo "============================================"
echo "Installation Complete!"
echo "============================================"
echo ""
echo "Certificates in: $SCRIPT_DIR/"
echo "  - ca.crt / ca.key          (CA — auth provider)"
echo "  - client.crt / client.key  (client cert for /metrics)"
echo ""
echo "Test: cd $SCRIPT_DIR && curl --cert client.crt --key client.key -k \"$ROX_CENTRAL_ADDRESS/metrics\""
echo ""
rm -f "$SCRIPT_DIR/.env.certs"
