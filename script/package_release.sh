#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT="WhiskerFlow"
VERSION="${VERSION:-0.4.0}"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/$PRODUCT-$VERSION"
APP_BUNDLE="$STAGING_DIR/$PRODUCT.app"
ZIP_PATH="$DIST_DIR/$PRODUCT-$VERSION.zip"
DMG_PATH="$DIST_DIR/$PRODUCT-$VERSION.dmg"

rm -rf "$STAGING_DIR" "$ZIP_PATH" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
export COPYFILE_DISABLE=1

CONFIGURATION=release "$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null

cp "$ROOT_DIR/Distribution/README.txt" "$STAGING_DIR/README.txt"
cp "$ROOT_DIR/Distribution/Install Whisper.command" "$STAGING_DIR/Install Whisper.command"
chmod +x "$STAGING_DIR/Install Whisper.command"
ln -s /Applications "$STAGING_DIR/Applications"

ditto -c -k --keepParent --norsrc "$STAGING_DIR" "$ZIP_PATH"
hdiutil create \
  -volname "$PRODUCT $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Packaged:"
echo "$ZIP_PATH"
echo "$DMG_PATH"
