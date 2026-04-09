#!/bin/bash
# Application deployment: clone demo-apps once, then apply manifests to local-cluster and aws-us in parallel.
# Uses oc --context=<ctx> so parallel jobs do not race on kubeconfig current-context.

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[APP-DEPLOY]${NC} ${DEPLOY_LOG_PREFIX:-}$1"
}

warning() {
    echo -e "${YELLOW}[APP-DEPLOY]${NC} ${DEPLOY_LOG_PREFIX:-}$1"
}

error() {
    echo -e "${RED}[APP-DEPLOY] ERROR:${NC} ${DEPLOY_LOG_PREFIX:-}$1" >&2
    echo -e "${RED}[APP-DEPLOY] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

context_exists() {
    oc config get-contexts -o name 2>/dev/null | sed 's|^context/||' | grep -qx "$1"
}

log "Validating prerequisites..."

if ! command -v oc >/dev/null 2>&1; then
    error "oc not found"
fi

log "Checking OpenShift CLI (default context)..."
if ! oc whoami &>/dev/null; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

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

TUTORIAL_HOME="$DEMO_APPS_REPO_DIR"
if [ ! -d "$TUTORIAL_HOME" ]; then
    error "TUTORIAL_HOME directory does not exist: $TUTORIAL_HOME"
fi

log "Setting TUTORIAL_HOME in ~/.bashrc..."
if [ -f ~/.bashrc ]; then
    sed -i '/^export TUTORIAL_HOME=/d' ~/.bashrc
fi
echo "export TUTORIAL_HOME=\"$TUTORIAL_HOME\"" >> ~/.bashrc
export TUTORIAL_HOME="$TUTORIAL_HOME"
log "✓ TUTORIAL_HOME=$TUTORIAL_HOME"

# Deploy to one cluster using explicit --context (safe for parallel execution)
deploy_to_cluster() {
    local CLUSTER_NAME="$1"
    local CLUSTER_CONTEXT="$2"

    log ""
    log "========================================================="
    log "Deploying applications to $CLUSTER_NAME ($CLUSTER_CONTEXT)"
    log "========================================================="

    if ! context_exists "$CLUSTER_CONTEXT"; then
        warning "Context '$CLUSTER_CONTEXT' not in kubeconfig — skipping."
        return 1
    fi

    if ! oc --context="$CLUSTER_CONTEXT" whoami &>/dev/null; then
        warning "Not authorized on $CLUSTER_CONTEXT — skipping."
        return 1
    fi
    log "✓ Connected as: $(oc --context="$CLUSTER_CONTEXT" whoami)"

    if [ -d "$TUTORIAL_HOME/k8s-deployment-manifests" ]; then
        log "Applying k8s-deployment-manifests (recursive)..."
        if oc --context="$CLUSTER_CONTEXT" apply -f "$TUTORIAL_HOME/k8s-deployment-manifests/" --recursive; then
            log "✓ Apply finished for $CLUSTER_NAME"
        else
            warning "Apply reported errors on $CLUSTER_NAME"
            return 1
        fi
    else
        warning "k8s-deployment-manifests not found: $TUTORIAL_HOME/k8s-deployment-manifests"
        return 1
    fi

    log "✓ Deployment step completed for $CLUSTER_NAME"
    return 0
}

# Start a deploy in the background from the MAIN shell (never use $(...) here). Command substitution
# runs a subshell that exits right after returning the PID; background children can then lose their
# stable environment, and writes to "$STAGING/rc-*" may hit "No such file or directory".
start_deploy_job() {
    local name="$1"
    local ctx="$2"
    local rcfile="$3"
    (
        exec 1>&2
        export DEPLOY_LOG_PREFIX="[$name] "
        deploy_to_cluster "$name" "$ctx"
        ec=$?
        printf '%s\n' "$ec" >"$rcfile"
        exit "$ec"
    ) &
    PIDS+=($!)
}

log ""
log "========================================================="
log "Starting parallel application deploy (local-cluster + aws-us)"
log "========================================================="

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

RC_LOCAL="${STAGING}/rc-local"
RC_AWS="${STAGING}/rc-aws"
echo 1 >"$RC_LOCAL"
echo 1 >"$RC_AWS"

PIDS=()

start_deploy_job "local-cluster" "local-cluster" "$RC_LOCAL"

if context_exists aws-us; then
    start_deploy_job "aws-us" "aws-us" "$RC_AWS"
else
    log "No aws-us context — only deploying local-cluster"
    echo 0 >"$RC_AWS"
fi

FAIL=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        FAIL=1
    fi
done

read -r EC_LOCAL <"$RC_LOCAL" || EC_LOCAL=1
read -r EC_AWS <"$RC_AWS" || EC_AWS=1

if [ "${EC_LOCAL:-1}" != "0" ]; then
    warning "local-cluster deploy reported failure (see messages above)"
    FAIL=1
fi
if context_exists aws-us && [ "${EC_AWS:-1}" != "0" ]; then
    warning "aws-us deploy reported failure (see messages above)"
    FAIL=1
fi

log ""
log "========================================================="
if [ "$FAIL" -eq 0 ]; then
    log "Application deployment completed (parallel run successful)"
else
    log "Application deployment finished with errors — review output above"
fi
log "========================================================="
log "Check workloads:"
log "  oc --context=local-cluster get pods -A"
if context_exists aws-us; then
    log "  oc --context=aws-us get pods -A"
fi
log ""

exit "$FAIL"
