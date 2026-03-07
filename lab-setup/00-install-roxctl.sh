#!/bin/bash
# Script to install roxctl CLI tool for Red Hat Advanced Cluster Security
# This script detects the OS and architecture, downloads roxctl, and installs it to the system PATH

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[ROXCTL-INSTALL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[ROXCTL-INSTALL]${NC} $1"
}

error() {
    echo -e "${RED}[ROXCTL-INSTALL] ERROR:${NC} $1" >&2
    exit 1
}

log "========================================================="
log "Installing roxctl CLI tool"
log "========================================================="

# Check current context and switch to local-cluster if needed
CURRENT_CONTEXT=$(oc config current-context 2>/dev/null || echo "")
if [ "$CURRENT_CONTEXT" != "local-cluster" ]; then
    log "Current context is '$CURRENT_CONTEXT'. Switching to 'local-cluster'..."
    if oc config use-context local-cluster >/dev/null 2>&1; then
        log "✓ Switched to 'local-cluster' context"
    else
        error "Failed to switch to 'local-cluster' context. Please ensure the context exists."
    fi
else
    log "✓ Already in 'local-cluster' context"
fi

# Detect OS and architecture
OS=$(uname -s)
ARCH=$(uname -m)

log "Detected OS: $OS"
log "Detected Architecture: $ARCH"

# Determine roxctl binary architecture based on OS and CPU architecture
case "$OS" in
    Linux)
        case "$ARCH" in
            x86_64)
                ROXCTL_ARCH="linux"
                ;;
            aarch64|arm64)
                ROXCTL_ARCH="linux_arm64"
                ;;
            *)
                error "Unsupported Linux architecture: $ARCH"
                ;;
        esac
        ;;
    Darwin)
        case "$ARCH" in
            x86_64)
                ROXCTL_ARCH="darwin"
                ;;
            arm64)
                ROXCTL_ARCH="darwin_arm64"
                ;;
            *)
                error "Unsupported macOS architecture: $ARCH"
                ;;
        esac
        ;;
    *)
        error "Unsupported operating system: $OS"
        ;;
esac

log "Using roxctl binary: $ROXCTL_ARCH"

# Set roxctl version
ROXCTL_VERSION="4.9.0"
ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${ROXCTL_VERSION}/bin/${ROXCTL_ARCH}/roxctl"
ROXCTL_TMP="/tmp/roxctl"

# Check if roxctl is already installed
if command -v roxctl >/dev/null 2>&1; then
    log "roxctl is already installed, checking version..."
    
    # Try to get version - handle both plain text and JSON output
    INSTALLED_VERSION=$(roxctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    
    # If that didn't work, try JSON format
    if [ -z "$INSTALLED_VERSION" ]; then
        INSTALLED_VERSION=$(roxctl version --output json 2>/dev/null | grep -oE '"version":\s*"[^"]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    fi
    
    if [ -n "$INSTALLED_VERSION" ] && [[ "$INSTALLED_VERSION" == 4.9.* ]]; then
        log "✓ roxctl version $INSTALLED_VERSION is already installed and up to date"
        log "roxctl CLI setup complete"
        exit 0
    else
        log "roxctl exists but is not version 4.9 (found: ${INSTALLED_VERSION:-unknown})"
        log "Downloading version $ROXCTL_VERSION..."
    fi
else
    log "roxctl not found, installing version $ROXCTL_VERSION..."
fi

# Download roxctl
log "Downloading roxctl from: $ROXCTL_URL"
if ! curl -k -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL"; then
    error "Failed to download roxctl from $ROXCTL_URL"
fi

# Make it executable
chmod +x "$ROXCTL_TMP"

# Determine installation location
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="$INSTALL_DIR/roxctl"
USER_BIN_DIR="$HOME/bin"

# Try to install to /usr/local/bin (requires sudo)
if command -v sudo >/dev/null 2>&1; then
    log "Installing roxctl to $INSTALL_PATH (requires sudo)..."
    if sudo mv "$ROXCTL_TMP" "$INSTALL_PATH" 2>/dev/null; then
        log "✓ roxctl installed successfully to $INSTALL_PATH"
        INSTALLED=true
    else
        warning "Failed to install to $INSTALL_PATH (sudo may require password)"
        INSTALLED=false
    fi
else
    warning "sudo not available, will try user directory"
    INSTALLED=false
fi

# Fallback to user's bin directory if system installation failed
if [ "$INSTALLED" = false ]; then
    log "Installing roxctl to user directory: $USER_BIN_DIR"
    
    # Create ~/bin if it doesn't exist
    if [ ! -d "$USER_BIN_DIR" ]; then
        mkdir -p "$USER_BIN_DIR"
        log "Created directory: $USER_BIN_DIR"
    fi
    
    # Move roxctl to user bin
    mv "$ROXCTL_TMP" "$USER_BIN_DIR/roxctl"
    INSTALL_PATH="$USER_BIN_DIR/roxctl"
    log "✓ roxctl installed successfully to $INSTALL_PATH"
    
    # Check if ~/bin is in PATH
    if [[ ":$PATH:" != *":$USER_BIN_DIR:"* ]]; then
        warning "$USER_BIN_DIR is not in PATH"
        log "Adding $USER_BIN_DIR to PATH in current session..."
        export PATH="$USER_BIN_DIR:$PATH"
        
        # Try to add to shell profile
        SHELL_PROFILE=""
        if [ -f "$HOME/.bashrc" ]; then
            SHELL_PROFILE="$HOME/.bashrc"
        elif [ -f "$HOME/.bash_profile" ]; then
            SHELL_PROFILE="$HOME/.bash_profile"
        elif [ -f "$HOME/.zshrc" ]; then
            SHELL_PROFILE="$HOME/.zshrc"
        fi
        
        if [ -n "$SHELL_PROFILE" ]; then
            if ! grep -q "export PATH=\"\$HOME/bin:\$PATH\"" "$SHELL_PROFILE" 2>/dev/null; then
                log "Adding $USER_BIN_DIR to PATH in $SHELL_PROFILE"
                echo '' >> "$SHELL_PROFILE"
                echo '# Add ~/bin to PATH for roxctl' >> "$SHELL_PROFILE"
                echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_PROFILE"
            fi
        fi
    fi
fi

# Verify installation
log "Verifying roxctl installation..."
if ! command -v roxctl >/dev/null 2>&1; then
    error "roxctl installation verification failed. Please ensure $INSTALL_PATH is in your PATH"
fi

# Get installed version for verification
INSTALLED_VERSION=$(roxctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
if [ -z "$INSTALLED_VERSION" ]; then
    INSTALLED_VERSION=$(roxctl version --output json 2>/dev/null | grep -oE '"version":\s*"[^"]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
fi

if [ -n "$INSTALLED_VERSION" ]; then
    log "✓ roxctl version $INSTALLED_VERSION is installed and working"
else
    warning "Could not verify roxctl version, but binary is accessible"
fi

log ""
log "========================================================="
log "roxctl CLI installation complete"
log "========================================================="
log "Installation path: $INSTALL_PATH"
if [ "$INSTALL_DIR" = "/usr/local/bin" ] && [ "$INSTALLED" = true ]; then
    log "roxctl is available system-wide"
else
    log "roxctl is installed in user directory"
    log "Make sure $USER_BIN_DIR is in your PATH"
fi
log "========================================================="

log ""
