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
if [[ -n "$RUNNING_PIDS" ]]; then
  while read -r pid; do kill -TERM "$pid"; done <<< "$RUNNING_PIDS"
fi
BUNDLE_IDENTIFIER_OVERRIDE="$BUNDLE_IDENTIFIER_OVERRIDE" \
  BUNDLE_NAME_OVERRIDE="$BUNDLE_NAME_OVERRIDE" \
  "$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null

echo "Launching $APP_BUNDLE"
/usr/bin/open -n "$APP_BUNDLE" --args "$@"

verify_process() {
  local attempts=0
  while (( attempts < 40 )); do
    if ps -axo command= | grep -F "$APP_BUNDLE/Contents/MacOS/$PRODUCT" | grep -v grep >/dev/null; then
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
