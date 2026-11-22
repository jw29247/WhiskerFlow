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
  "$APP_BUNDLE/Contents/Resources/WhiskerFlow_WhiskerFlow.bundle/CleanupNotices.txt"
codesign --verify --deep --strict "$APP_BUNDLE"

# The app runs only on Apple Silicon, so it ships no Intel code: the Cleanup
# runtime is thinned to arm64 when bundled. Sparkle is the one deliberate
# exception; its signed helpers are embedded exactly as Sparkle ships them.
[[ "$(lipo -archs "$APP_BUNDLE/Contents/Frameworks/llama.framework/llama")" == arm64 ]]
while IFS= read -r -d '' file; do
  archs="$(lipo -archs "$file" 2>/dev/null)" || continue
  [[ " $archs " == *" x86_64 "* ]] || continue
  case "${file#"$APP_BUNDLE"/}" in
    Contents/Frameworks/Sparkle.framework/*) continue ;;
  esac
  echo "FAIL: $file contains an x86_64 slice" >&2
  exit 1
done < <(find "$APP_BUNDLE" -type f -print0)

DEV_BUNDLE="$ROOT_DIR/.build/$CONFIGURATION/WhiskerFlow Test Dev.app"
BUNDLE_IDENTIFIER_OVERRIDE=agency.thatworks.WhiskerFlow.dev \
  BUNDLE_NAME_OVERRIDE='WhiskerFlow Dev' \
  "$ROOT_DIR/script/bundle_app.sh" "$DEV_BUNDLE" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEV_BUNDLE/Contents/Info.plist")" == agency.thatworks.WhiskerFlow.dev ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$DEV_BUNDLE/Contents/Info.plist")" == 'WhiskerFlow Dev' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" == agency.thatworks.WhiskerFlow ]]
codesign --verify --deep --strict "$DEV_BUNDLE"
echo "PASS: packaged resources, release version, signatures, and separate development identity"
