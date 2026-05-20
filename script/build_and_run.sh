#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
PRODUCT="WhiskerFlow"
APP_BUNDLE="$ROOT_DIR/.build/$CONFIGURATION/$PRODUCT.app"

"$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null

echo "Launching $APP_BUNDLE"
"$APP_BUNDLE/Contents/MacOS/$PRODUCT" "$@"
