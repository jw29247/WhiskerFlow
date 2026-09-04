#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_BUNDLE="$ROOT_DIR/.build/$CONFIGURATION/WhiskerFlow.app"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"

"$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_BUNDLE/Contents/Info.plist")" == \
     "$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST")" ]]
done
cmp "$ROOT_DIR/Sources/WhiskerFlow/Resources/shared-vocabulary.json" \
  "$APP_BUNDLE/Contents/Resources/WhiskerFlow_WhiskerFlow.bundle/shared-vocabulary.json"
codesign --verify --deep --strict "$APP_BUNDLE"

DEV_BUNDLE="$ROOT_DIR/.build/$CONFIGURATION/WhiskerFlow Test Dev.app"
BUNDLE_IDENTIFIER_OVERRIDE=agency.thatworks.WhiskerFlow.dev \
  BUNDLE_NAME_OVERRIDE='WhiskerFlow Dev' \
  "$ROOT_DIR/script/bundle_app.sh" "$DEV_BUNDLE" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEV_BUNDLE/Contents/Info.plist")" == agency.thatworks.WhiskerFlow.dev ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$DEV_BUNDLE/Contents/Info.plist")" == 'WhiskerFlow Dev' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" == agency.thatworks.WhiskerFlow ]]
codesign --verify --deep --strict "$DEV_BUNDLE"
echo "PASS: packaged resources, release version, signatures, and separate development identity"
