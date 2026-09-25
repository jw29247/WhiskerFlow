#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
PRODUCT="WhiskerFlow"
APP_BUNDLE="${1:-$ROOT_DIR/.build/$CONFIGURATION/$PRODUCT.app}"

# When SIGN_IDENTITY is set (e.g. a "Developer ID Application: …" identity), the
# app is signed for notarized distribution: hardened runtime + entitlements +
# secure timestamp. Otherwise it falls back to ad-hoc signing for local use.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/Resources/WhiskerFlow.entitlements}"
BUNDLE_IDENTIFIER_OVERRIDE="${BUNDLE_IDENTIFIER_OVERRIDE:-}"
BUNDLE_NAME_OVERRIDE="${BUNDLE_NAME_OVERRIDE:-}"
# Debug bundles keep DEBUG-only behavior (no Sparkle updates, verification
# commands) but are compiled with -O by default: unoptimized FluidAudio decoding
# is 1.5–1.8x slower, so a -Onone candidate misrepresents dictation latency.
# The optimized build uses its own scratch path so `swift test` keeps its cache.
# OPTIMIZE=0 restores the plain -Onone build for debugger sessions.
OPTIMIZE="${OPTIMIZE:-1}"
BUILD_ROOT="$ROOT_DIR/.build"

cd "$ROOT_DIR"

echo "Building $PRODUCT ($CONFIGURATION)"
if [[ "$CONFIGURATION" == "release" ]]; then
  # Keep developer/workspace paths out of both the executable and its dSYM.
  swift build --configuration "$CONFIGURATION" \
    -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=." \
    -Xcc "-fdebug-prefix-map=$ROOT_DIR=." \
    -Xswiftc -Xfrontend -Xswiftc -no-clang-module-breadcrumbs
elif [[ "$OPTIMIZE" == "1" ]]; then
  BUILD_ROOT="$ROOT_DIR/.build/optimized"
  swift build --configuration "$CONFIGURATION" --scratch-path "$BUILD_ROOT" -Xswiftc -O
else
  swift build --configuration "$CONFIGURATION"
fi

BINARY="$BUILD_ROOT/$CONFIGURATION/$PRODUCT"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$PRODUCT"

if [[ ! -x "$BINARY" ]]; then
  echo "Built binary not found at $BINARY" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BINARY"
cp "$BUILD_ROOT/$CONFIGURATION/WhiskerFlowMeetBridge" "$APP_BUNDLE/Contents/MacOS/WhiskerFlowMeetBridge"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
BUILD_REVISION="$(git rev-parse --short=12 HEAD)-$(date -u +%Y%m%dT%H%M%SZ)"
/usr/libexec/PlistBuddy -c "Add :WhiskerFlowBuildRevision string $BUILD_REVISION" "$APP_BUNDLE/Contents/Info.plist"
if [[ -n "$BUNDLE_IDENTIFIER_OVERRIDE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER_OVERRIDE" \
    "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ -n "$BUNDLE_NAME_OVERRIDE" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $BUNDLE_NAME_OVERRIDE" \
    "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ -n "${WHISKERFLOW_SENTRY_DSN:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :WhiskerFlowSentryDSN $WHISKERFLOW_SENTRY_DSN" \
    "$APP_BUNDLE/Contents/Info.plist"
fi
printf "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Bundle SwiftPM dependency resource bundles (e.g. WhisperKit) so the app is self-contained.
BUILD_DIR="$(dirname "$BINARY")"
shopt -s nullglob
for bundle in "$BUILD_DIR"/*.bundle; do
  cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done
shopt -u nullglob

# Embed Sparkle.framework for in-app auto-updates. SwiftPM drops the framework
# next to the built binary; copy it in and add an rpath so the binary can load
# it at runtime. (install_name_tool invalidates SwiftPM's ad-hoc signature, but
# the app is fully re-signed below.)
SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Frameworks"
  ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
  if ! otool -l "$APP_BINARY" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
  fi
fi

# Sign inner-to-outer (Apple discourages --deep for real signing). Only nested
# bundles that actually contain Mach-O code need their own signature; resource-
# only bundles (e.g. swift-transformers_Hub.bundle) are sealed by the app
# signature and cannot be code-signed standalone.
has_macho() {
  # Count instead of `grep -q`: an early exit would SIGPIPE `file`, and under
  # pipefail that failure would read as "no Mach-O" and skip signing.
  local count
  count="$(find "$1" -type f -exec file {} + 2>/dev/null | grep -c "Mach-O" || true)"
  [[ "${count:-0}" -gt 0 ]]
}

# Sign one nested item with the active identity: Developer ID + hardened runtime
# + secure timestamp when SIGN_IDENTITY is set, ad-hoc otherwise.
codesign_one() {
  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1" >/dev/null
  else
    codesign --force --sign - "$1" >/dev/null
  fi
}

# Sparkle ships several nested helpers that each need their own signature; sign
# them deepest-first, then the framework, before the outer app is signed.
sign_sparkle_framework() {
  local fw="$1"
  local base="$fw/Versions/B"
  local item
  for item in \
    "$base/XPCServices/Downloader.xpc" \
    "$base/XPCServices/Installer.xpc" \
    "$base/Autoupdate" \
    "$base/Updater.app"; do
    [[ -e "$item" ]] && codesign_one "$item"
  done
  codesign_one "$fw"
}

shopt -s nullglob
for nested in "$APP_BUNDLE"/Contents/Resources/*.bundle; do
  has_macho "$nested" || continue
  codesign_one "$nested"
done
shopt -u nullglob

if [[ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
  sign_sparkle_framework "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

codesign_one "$APP_BUNDLE/Contents/MacOS/WhiskerFlowMeetBridge"

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with: $SIGN_IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
  codesign --verify --strict --verbose=2 "$APP_BUNDLE"
else
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
  xattr -dr com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
fi

echo "$APP_BUNDLE"
