#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$ROOT_DIR/.build/local-apps}"
PRODUCT="WhiskerFlow"
APP_BUNDLE="$INSTALL_DIR/$PRODUCT Dev.app"
BUNDLE_IDENTIFIER_OVERRIDE="agency.thatworks.WhiskerFlow.dev"

mkdir -p "$INSTALL_DIR"

pkill -f "$PRODUCT.app/Contents/MacOS/$PRODUCT" 2>/dev/null || true
sleep 0.5

BUNDLE_IDENTIFIER_OVERRIDE="$BUNDLE_IDENTIFIER_OVERRIDE" \
  BUNDLE_NAME_OVERRIDE="$PRODUCT Dev" \
  "$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null

echo "Installed $APP_BUNDLE"
echo
echo "Opening installed app..."
open "$APP_BUNDLE"
echo
echo "This isolated development build does not replace the production app or its permissions."
echo "For auto-paste, allow this development app in:"
echo "System Settings > Privacy & Security > Accessibility"
