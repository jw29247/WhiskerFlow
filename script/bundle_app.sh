#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
PRODUCT="WhiskerFlow"
APP_BUNDLE="${1:-$ROOT_DIR/.build/$CONFIGURATION/$PRODUCT.app}"

cd "$ROOT_DIR"

echo "Building $PRODUCT ($CONFIGURATION)"
swift build --configuration "$CONFIGURATION"

BINARY="$ROOT_DIR/.build/$CONFIGURATION/$PRODUCT"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$PRODUCT"

if [[ ! -x "$BINARY" ]]; then
  echo "Built binary not found at $BINARY" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

echo "$APP_BUNDLE"
