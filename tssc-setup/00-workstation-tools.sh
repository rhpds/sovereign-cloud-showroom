#!/bin/bash
# Bastion / lab workstation tools for TSSC module (matches module-03 setup).
# Installs podman (RHEL/Fedora) and cosign + gitsign:
#   - Prefer the Red Hat TSSC installer when the RHTAS client-server Route exists (CLIs from the cluster).
#   - Otherwise install release binaries from GitHub (no Route required; avoids races with parallel deploy).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[TSSC-TOOLS]${NC} $1"; }
warning() { echo -e "${YELLOW}[TSSC-TOOLS]${NC} $1"; }
error() { echo -e "${RED}[TSSC-TOOLS] ERROR:${NC} $1" >&2; exit 1; }

COSIGN_GITSIGN_INSTALLER_URL="${COSIGN_GITSIGN_INSTALLER_URL:-https://raw.githubusercontent.com/redhat-tssc-tmm/security-roadshow/main/cosign_gitsign_installer.sh}"
# Fallback when Route is missing or upstream installer fails (override for air-gapped mirrors)
COSIGN_VERSION="${COSIGN_VERSION:-v2.4.1}"
GITSIGN_VERSION="${GITSIGN_VERSION:-v0.14.0}"

rhtas_client_server_route_ready() {
    command -v oc &>/dev/null || return 1
    oc whoami &>/dev/null || return 1
    oc get routes -l app.kubernetes.io/component=client-server -n trusted-artifact-signer --no-headers 2>/dev/null | grep -q .
}

install_cosign_gitsign_rhtas_installer() {
    curl -fsSL "$COSIGN_GITSIGN_INSTALLER_URL" | bash
}

install_cosign_gitsign_github() {
    local arch goarch gv tmp
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) goarch=amd64 ;;
        aarch64|arm64) goarch=arm64 ;;
        *) error "Unsupported architecture for GitHub fallback: $arch" ;;
    esac

    tmp=$(mktemp -d)
    cleanup() { rm -rf "$tmp"; }
    trap cleanup EXIT

    log "Downloading cosign ${COSIGN_VERSION} from GitHub..."
    curl -fsSL -o "$tmp/cosign" "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${goarch}"
    chmod +x "$tmp/cosign"
    if [ "$(id -u)" -eq 0 ]; then
        mv "$tmp/cosign" /usr/local/bin/cosign
    else
        sudo mv "$tmp/cosign" /usr/local/bin/cosign
    fi

    gv="${GITSIGN_VERSION#v}"
    log "Downloading gitsign ${GITSIGN_VERSION} from GitHub..."
    curl -fsSL -o "$tmp/gitsign" "https://github.com/sigstore/gitsign/releases/download/${GITSIGN_VERSION}/gitsign_${gv}_linux_${goarch}"
    chmod +x "$tmp/gitsign"
    if [ "$(id -u)" -eq 0 ]; then
        mv "$tmp/gitsign" /usr/local/bin/gitsign
    else
        sudo mv "$tmp/gitsign" /usr/local/bin/gitsign
    fi

    trap - EXIT
    cleanup
}

log "Installing workstation tools (podman, cosign, gitsign)..."

if command -v podman &>/dev/null; then
    log "✓ podman already present: $(command -v podman)"
else
    if command -v dnf &>/dev/null; then
        log "Installing podman via dnf..."
        if [ "$(id -u)" -eq 0 ]; then
            dnf -y install podman
        else
            sudo dnf -y install podman
        fi
        log "✓ podman installed"
    else
        warning "dnf not found; skipping podman (install podman manually if needed)"
    fi
fi

log "Installing cosign and gitsign..."
if rhtas_client_server_route_ready; then
    log "RHTAS client-server Route found; running Red Hat TSSC installer..."
    if install_cosign_gitsign_rhtas_installer; then
        :
    else
        warning "RHTAS installer failed; falling back to GitHub releases..."
        install_cosign_gitsign_github
    fi
else
    warning "No client-server Route in trusted-artifact-signer (or oc not logged in). Installing cosign/gitsign from GitHub releases..."
    install_cosign_gitsign_github
fi

log "✓ cosign / gitsign installation finished"
if command -v cosign &>/dev/null; then
    cosign version || true
fi
if command -v gitsign &>/dev/null; then
    gitsign --version 2>/dev/null || gitsign version 2>/dev/null || true
fi

log "Workstation tools step finished."
