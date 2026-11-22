#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
APP_BUNDLE="$ROOT_DIR/.build/$CONFIGURATION/WhiskerFlow.app"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
# shellcheck source=lib/resource_bundle.sh
source "$ROOT_DIR/script/lib/resource_bundle.sh"

"$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
  [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_BUNDLE/Contents/Info.plist")" == \
     "$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST")" ]]
done
test -f "$APP_BUNDLE/Contents/Frameworks/llama.framework/llama"
# The Now Playing helper must not record where it was built.
HELPER="$APP_BUNDLE/Contents/Frameworks/libWhiskerFlowNowPlaying.dylib"
HELPER_NAMES="$(otool -D "$HELPER")"
[[ "$HELPER_NAMES" == *$'\n'"@rpath/libWhiskerFlowNowPlaying.dylib"* ]]
if LC_ALL=C /usr/bin/grep -qF -e "$HOME/" "$HELPER"; then
  echo "FAIL: the Now Playing helper contains a local home-directory path" >&2
  exit 1
fi
cmp "$ROOT_DIR/Sources/WhiskerFlow/Resources/CleanupNotices.txt" \
  "$(resource_bundle_file "$APP_BUNDLE/Contents/Resources/WhiskerFlow_WhiskerFlow.bundle" CleanupNotices.txt)"
# The glossary is downloaded from Atlas; the app must not ship a copy.
# Not `find … | grep -q`: under pipefail a second match can kill `find` with
# SIGPIPE, which would read as "none found".
if [[ -n "$(find "$APP_BUNDLE" -name shared-vocabulary.json -print -quit)" ]]; then
  echo "FAIL: the app bundle contains a copy of the shared glossary" >&2
  exit 1
fi
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
