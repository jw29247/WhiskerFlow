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

# Sign inner-to-outer (Apple discourages --deep for real signing). Only nested
# bundles that actually contain Mach-O code need their own signature; resource-
# only bundles (e.g. swift-transformers_Hub.bundle) are sealed by the app
# signature and cannot be code-signed standalone.
has_macho() {
  find "$1" -type f -print0 2>/dev/null | xargs -0 file 2>/dev/null | grep -q "Mach-O"
}

shopt -s nullglob
for nested in "$APP_BUNDLE"/Contents/Resources/*.bundle; do
  has_macho "$nested" || continue
  if [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$nested" >/dev/null
  else
    codesign --force --sign - "$nested" >/dev/null
  fi
done
shopt -u nullglob

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
