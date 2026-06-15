#!/usr/bin/env bash
# Stop the local httpd container, rebuild the Antora site, and serve it again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/stop.sh"
"${SCRIPT_DIR}/build.sh"
"${SCRIPT_DIR}/serve.sh"
