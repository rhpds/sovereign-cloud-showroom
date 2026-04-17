#!/usr/bin/env bash
# Build the Showroom static site with Antora (writes to ./www at repo root).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_common.sh"

cd "${SHOWROOM_REPO_ROOT}"

echo "Removing previous site under www/..."
mkdir -p www
rm -rf www/*

echo "Building Antora site from ${SHOWROOM_SITE_YML}..."
npx antora --fetch "${SHOWROOM_SITE_YML}"

echo "Build complete: ${SHOWROOM_WWW}"
echo "Serve locally with: ${SCRIPT_DIR}/serve.sh"
