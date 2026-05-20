#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
PRODUCT="WhiskerFlow"
APP_BUNDLE="$INSTALL_DIR/$PRODUCT.app"

mkdir -p "$INSTALL_DIR"

pkill -f "$PRODUCT.app/Contents/MacOS/$PRODUCT" 2>/dev/null || true
sleep 0.5

"$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null

echo "Installed $APP_BUNDLE"
echo
echo "Opening installed app..."
open "$APP_BUNDLE"
echo
echo "For auto-paste, allow this installed app in:"
echo "System Settings > Privacy & Security > Accessibility"
