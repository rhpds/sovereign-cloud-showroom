#!/bin/bash
# Run lab-setup, tssc-setup, and ai-setup in parallel with a live progress bar.
# On failure, prints re-run commands and keeps logs under $LOG_DIR.
#
# Already parallel at this layer:
#   [1] lab-setup/run-all-setup.sh   — 01–07 in order, then workstation tools (cosign/gitsign need RHTAS route);
#       05 deploys local-cluster + aws-us in parallel via oc --context.
#   [2] tssc-setup/setup.sh          — Keycloak → operator → deploy (--skip-workstation-tools: tools installed in [1]).
#   [3] ai-setup/setup.sh            — operator + cluster checks run in parallel.

set -uo pipefail

# RHACS / roxctl: required for gRPC clients on some environments; persist for future shells.
export GRPC_ENFORCE_ALPN_ENABLED=false
if [[ -n "${HOME:-}" && -w "${HOME:-}" ]]; then
  _bashrc="${HOME}/.bashrc"
  if [[ -f "$_bashrc" ]] && ! grep -Fq 'GRPC_ENFORCE_ALPN_ENABLED' "$_bashrc" 2>/dev/null; then
    {
      echo ''
      echo '# svc-lab (RHACS / roxctl)'
      echo 'export GRPC_ENFORCE_ALPN_ENABLED=false'
    } >>"$_bashrc" 2>/dev/null || true
  fi
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT" || exit 1

LAB_SCRIPT="$REPO_ROOT/lab-setup/run-all-setup.sh"
TSSC_SCRIPT="$REPO_ROOT/tssc-setup/setup.sh"
AI_SCRIPT="$REPO_ROOT/ai-setup/setup.sh"

for s in "$LAB_SCRIPT" "$TSSC_SCRIPT" "$AI_SCRIPT"; do
  if [[ ! -f "$s" ]]; then
    echo "ERROR: script not found: $s" >&2
    exit 1
  fi
done

LOG_DIR=$(mktemp -d /tmp/svc-lab-parallel-setup.XXXXXX)
SETUP_ALL_OK=0

log_cleanup() {
  if [[ "$SETUP_ALL_OK" -eq 1 ]]; then
    rm -rf "$LOG_DIR" 2>/dev/null || true
  else
    echo ""
    echo "Setup logs (kept because one or more steps failed): $LOG_DIR"
  fi
}
trap log_cleanup EXIT

cleanup_children() {
  kill "$PID_LAB" "$PID_TSSC" "$PID_AI" 2>/dev/null || true
  wait "$PID_LAB" "$PID_TSSC" "$PID_AI" 2>/dev/null || true
}
trap 'echo ""; echo "Interrupted."; cleanup_children; exit 130' INT TERM

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Lab setup (parallel)${NC}"
echo "  [1] Lab / RHACS / monitoring  —  lab-setup/run-all-setup.sh"
echo "  [2] Trusted Artifact Signer   —  tssc-setup/setup.sh"
echo "  [3] OpenShift AI verification —  ai-setup/setup.sh"
echo ""

bash "$LAB_SCRIPT" >"$LOG_DIR/lab.log" 2>&1 &
PID_LAB=$!
bash "$TSSC_SCRIPT" --skip-workstation-tools >"$LOG_DIR/tssc.log" 2>&1 &
PID_TSSC=$!
bash "$AI_SCRIPT" >"$LOG_DIR/ai.log" 2>&1 &
PID_AI=$!

TOTAL=3
spin='|/-\'
si=0
start_ts=$(date +%s)

draw_bar() {
  local done=$1 total=$2 width=${3:-28}
  local filled=$((done * width / total))
  [[ "$filled" -gt "$width" ]] && filled=$width
  local empty=$((width - filled))
  printf '%*s' "$filled" '' | tr ' ' '#'
  printf '%*s' "$empty" '' | tr ' ' '.'
}

any_running() {
  kill -0 "$PID_LAB" 2>/dev/null && return 0
  kill -0 "$PID_TSSC" 2>/dev/null && return 0
  kill -0 "$PID_AI" 2>/dev/null && return 0
  return 1
}

echo -e "${YELLOW}Progress (streams finish in any order):${NC}"
while any_running; do
  n_run=0
  kill -0 "$PID_LAB" 2>/dev/null && n_run=$((n_run + 1))
  kill -0 "$PID_TSSC" 2>/dev/null && n_run=$((n_run + 1))
  kill -0 "$PID_AI" 2>/dev/null && n_run=$((n_run + 1))
  completed=$((TOTAL - n_run))
  elapsed=$(($(date +%s) - start_ts))
  sc=${spin:si:1}
  si=$(((si + 1) % 4))
  bar=$(draw_bar "$completed" "$TOTAL")
  # Pad line so short updates clear previous longer line
  printf '\r  %s  [%s]  %d of %d finished   %4ds   ' "$sc" "$bar" "$completed" "$TOTAL" "$elapsed"
  sleep 0.25
done
printf '\r  %s  [%s]  %d of %d finished   %4ds   \n' ' ' "$(draw_bar "$TOTAL" "$TOTAL")" "$TOTAL" "$TOTAL" "$(( $(date +%s) - start_ts ))"

wait "$PID_LAB"
EC_LAB=$?
wait "$PID_TSSC"
EC_TSSC=$?
wait "$PID_AI"
EC_AI=$?

echo ""

failed=0
[[ "$EC_LAB" -eq 0 ]] || failed=1
[[ "$EC_TSSC" -eq 0 ]] || failed=1
[[ "$EC_AI" -eq 0 ]] || failed=1

if [[ "$failed" -eq 0 ]]; then
  SETUP_ALL_OK=1
  echo -e "${GREEN}All three setup scripts completed successfully.${NC}"
  exit 0
fi

echo -e "${RED}One or more setup scripts failed. Re-run only what failed:${NC}"
echo ""

if [[ "$EC_LAB" -ne 0 ]]; then
  echo -e "${RED}[1] Lab setup failed (exit $EC_LAB)${NC}"
  echo "    Log: $LOG_DIR/lab.log"
  echo "    Re-run:"
  echo "      cd $REPO_ROOT && bash lab-setup/run-all-setup.sh"
  echo ""
  tail -n 25 "$LOG_DIR/lab.log" 2>/dev/null | sed 's/^/    | /'
  echo ""
fi

if [[ "$EC_TSSC" -ne 0 ]]; then
  echo -e "${RED}[2] TSSC setup failed (exit $EC_TSSC)${NC}"
  echo "    Log: $LOG_DIR/tssc.log"
  echo "    Re-run:"
  echo "      cd $REPO_ROOT && bash tssc-setup/setup.sh"
  echo ""
  tail -n 25 "$LOG_DIR/tssc.log" 2>/dev/null | sed 's/^/    | /'
  echo ""
fi

if [[ "$EC_AI" -ne 0 ]]; then
  echo -e "${RED}[3] OpenShift AI verification failed (exit $EC_AI)${NC}"
  echo "    Log: $LOG_DIR/ai.log"
  echo "    Re-run:"
  echo "      cd $REPO_ROOT && bash ai-setup/setup.sh"
  echo ""
  tail -n 25 "$LOG_DIR/ai.log" 2>/dev/null | sed 's/^/    | /'
  echo ""
fi

echo -e "${YELLOW}After fixing the issue, you can re-run everything in parallel again:${NC}"
echo "  cd $REPO_ROOT && bash setup.sh"
echo ""

exit 1
