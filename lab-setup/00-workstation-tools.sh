#!/bin/bash
# Bastion tools for TSSC module (podman, cosign, gitsign).
# Delegates to the canonical installer in tssc-setup/ (single source of truth).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$SCRIPT_DIR/../tssc-setup/00-workstation-tools.sh"
