#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
PRODUCT="WhiskerFlow"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/.build/$CONFIGURATION/$PRODUCT Dev.app}"
BUNDLE_IDENTIFIER_OVERRIDE="${BUNDLE_IDENTIFIER_OVERRIDE:-agency.thatworks.WhiskerFlow.dev}"
BUNDLE_NAME_OVERRIDE="${BUNDLE_NAME_OVERRIDE:-$PRODUCT Dev}"
MODE="${1:-}"
if (( $# > 0 )); then shift; fi

# Stop only this candidate, never another installed WhiskerFlow build.
# App paths contain spaces; match the command suffix without splitting it.
RUNNING_PIDS="$(ps -axo pid=,command= | while read -r pid command; do
  if [[ "$command" == "$APP_BUNDLE/Contents/MacOS/$PRODUCT"* ]]; then echo "$pid"; fi
done)"

# Wait for every pid in $RUNNING_PIDS to exit, up to $1 quarter-second polls.
wait_for_exit() {
  local polls=0 pid alive
  while (( polls < $1 )); do
    alive=0
    while read -r pid; do
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done <<< "$RUNNING_PIDS"
    if (( alive == 0 )); then return 0; fi
    sleep 0.25
    polls=$((polls + 1))
  done
  return 1
}

if [[ -n "$RUNNING_PIDS" ]]; then
  # Quit through AppKit per pid so applicationShouldTerminate drains pending
  # transcript/meeting persistence; SIGTERM would skip it. Quitting by bundle id
  # could hit another worktree's dev build, which shares the identifier.
  while read -r pid; do
    /usr/bin/osascript -l JavaScript -e "ObjC.import('AppKit'); \
      const app = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); \
      if (app) { app.terminate; }" >/dev/null 2>&1 || true
  done <<< "$RUNNING_PIDS"
  # Draining is bounded in the app but slower Macs need longer; escalate only
  # after a generous wait so the old bundle is gone before it is replaced.
  if ! wait_for_exit 120; then
    echo "Previous $PRODUCT did not quit; sending SIGTERM" >&2
    while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done <<< "$RUNNING_PIDS"
    if ! wait_for_exit 20; then
      while read -r pid; do kill -KILL "$pid" 2>/dev/null || true; done <<< "$RUNNING_PIDS"
      wait_for_exit 20 || true
    fi
  fi
fi
BUNDLE_IDENTIFIER_OVERRIDE="$BUNDLE_IDENTIFIER_OVERRIDE" \
  BUNDLE_NAME_OVERRIDE="$BUNDLE_NAME_OVERRIDE" \
  "$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null

echo "Launching $APP_BUNDLE"
/usr/bin/open -n "$APP_BUNDLE" --args "$@"

verify_process() {
  local attempts=0
  while (( attempts < 40 )); do
    # Only a pid that wasn't running before the relaunch counts.
    local new_pids
    new_pids="$(ps -axo pid=,command= | while read -r pid command; do
      if [[ "$command" == "$APP_BUNDLE/Contents/MacOS/$PRODUCT"* ]] \
        && ! grep -qx "$pid" <<< "$RUNNING_PIDS"; then echo "$pid"; fi
    done)"
    if [[ -n "$new_pids" ]]; then
      echo "$PRODUCT is running"
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  echo "ERROR: $PRODUCT did not stay running after launch" >&2
  return 1
}

case "$MODE" in
  "" ) ;;
  --verify ) verify_process ;;
  --logs )
    verify_process
    exec /usr/bin/log stream --info --predicate "process == '$PRODUCT'"
    ;;
  * )
    echo "Usage: $0 [--verify|--logs]" >&2
    exit 2
    ;;
esac
