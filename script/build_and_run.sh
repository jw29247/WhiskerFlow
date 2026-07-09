#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
PRODUCT="WhiskerFlow"
APP_BUNDLE="$ROOT_DIR/.build/$CONFIGURATION/$PRODUCT.app"
MODE="${1:-}"

pkill -x "$PRODUCT" 2>/dev/null || true
"$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null

echo "Launching $APP_BUNDLE"
/usr/bin/open -n "$APP_BUNDLE"

verify_process() {
  local attempts=0
  while (( attempts < 40 )); do
    if pgrep -x "$PRODUCT" >/dev/null; then
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
