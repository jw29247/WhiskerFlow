#!/usr/bin/env bash
#
# One-command signed + notarized release for sharing with the team.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + Developer ID Application).
#   2. Stored notary credentials under a keychain profile, e.g.:
#        xcrun notarytool store-credentials "WhiskerFlow-Notary" \
#          --apple-id "you@example.com" --team-id "G9U38P58ZY" \
#          --password "app-specific-password"
#      (or use an App Store Connect API key: --key / --key-id / --issuer)
#
# Usage:
#   VERSION=0.3.0 script/notarize.sh
#
# Env overrides:
#   DEVELOPER_ID    full signing identity (default: first "Developer ID Application" in keychain)
#   NOTARY_PROFILE  notarytool keychain profile name (default: WhiskerFlow-Notary)
#   VERSION         release version (default: 0.3.0)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT="WhiskerFlow"
VERSION="${VERSION:-0.4.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-WhiskerFlow-Notary}"
REPO="${REPO:-jw29247/WhiskerFlow}"

DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/$PRODUCT-$VERSION"
APP_BUNDLE="$STAGING_DIR/$PRODUCT.app"
APP_ZIP="$DIST_DIR/$PRODUCT-$VERSION-app.zip"
DMG_PATH="$DIST_DIR/$PRODUCT-$VERSION.dmg"
SPARKLE_ZIP="$DIST_DIR/$PRODUCT-$VERSION.zip"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/$PRODUCT-$VERSION.zip"

# --- Auto-update preflight: a Sparkle public key must be set, or shipped builds
#     would reject every update. Generate it once with script/sparkle_keygen.sh.
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
SU_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null || true)"
if [[ -z "$SU_KEY" || "$SU_KEY" == "__SPARKLE_PUBLIC_ED_KEY__" ]]; then
  echo "ERROR: SUPublicEDKey is not set in Resources/Info.plist." >&2
  echo "       Run script/sparkle_keygen.sh once, commit the result, then retry." >&2
  exit 1
fi

# --- Resolve the Developer ID Application signing identity --------------------
SIGN_IDENTITY="${DEVELOPER_ID:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  cat >&2 <<'MSG'
ERROR: No "Developer ID Application" certificate found in your keychain.

Create one, then re-run:
  • Xcode > Settings > Accounts > (your team) > Manage Certificates
  • Click + > "Developer ID Application"
Or set DEVELOPER_ID="Developer ID Application: Name (TEAMID)".

Note: an "Apple Development" certificate is NOT sufficient for notarization.
MSG
  exit 1
fi
echo "==> Signing identity: $SIGN_IDENTITY"

# --- Clean staging ------------------------------------------------------------
rm -rf "$STAGING_DIR" "$APP_ZIP" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
export COPYFILE_DISABLE=1

# --- 1. Build + Developer ID sign (hardened runtime + entitlements) -----------
CONFIGURATION=release SIGN_IDENTITY="$SIGN_IDENTITY" \
  "$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null
echo "==> Built & signed $APP_BUNDLE"

# --- 2. Notarize the app and staple the ticket onto it (works offline) --------
ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
echo "==> Submitting app for notarization (a few minutes)…"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_BUNDLE"
rm -f "$APP_ZIP"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE" || true
echo "==> Notarized & stapled the app"

# --- 3. Stage DMG contents ----------------------------------------------------
cp "$ROOT_DIR/Distribution/README.txt" "$STAGING_DIR/README.txt"
cp "$ROOT_DIR/Distribution/Install Whisper.command" "$STAGING_DIR/Install Whisper.command"
chmod +x "$STAGING_DIR/Install Whisper.command"
ln -s /Applications "$STAGING_DIR/Applications"

# --- 4. Build, notarize, and staple the DMG (the artifact the team downloads) -
hdiutil create -volname "$PRODUCT $VERSION" -srcfolder "$STAGING_DIR" \
  -ov -format UDZO "$DMG_PATH" >/dev/null
echo "==> Submitting DMG for notarization…"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
echo "==> Notarized & stapled $DMG_PATH"

# --- 4b. Sparkle update archive + appcast -------------------------------------
# Sparkle updates from a zipped copy of the *notarized, stapled* app (the ticket
# travels inside the zip, so Gatekeeper validates offline after the in-place
# swap). The enclosure URL points at the GitHub release asset uploaded below.
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
rm -f "$SPARKLE_ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$SPARKLE_ZIP"
ZIP="$SPARKLE_ZIP" VERSION="$VERSION" BUILD="$BUILD_NUMBER" URL="$DOWNLOAD_URL" \
  NOTES="${NOTES:-}" "$ROOT_DIR/script/update_appcast.sh"
echo "==> Built $SPARKLE_ZIP and updated appcast.xml (build $BUILD_NUMBER)"

# --- 5. Update the Homebrew cask with the real version + checksum -------------
SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
CASK="$ROOT_DIR/Casks/whiskerflow.rb"
/usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
/usr/bin/sed -i '' -E "s/^  sha256 .*/  sha256 \"$SHA\"/" "$CASK"

cat <<MSG

==> Done.
    DMG (fresh installs):  $DMG_PATH
    ZIP (auto-update):     $SPARKLE_ZIP
    sha256 (DMG):          $SHA
    Updated:               appcast.xml + $CASK

Publish BOTH assets (the appcast enclosure points at the .zip), then commit so
the appcast + cask go live on main:
    gh release create "v$VERSION" "$DMG_PATH" "$SPARKLE_ZIP" \\
      --repo "$REPO" --title "$PRODUCT $VERSION" --notes "What changed…"
    git commit -am "release: $PRODUCT $VERSION" && git push

Existing users on $PRODUCT 0.4.0+ receive this automatically via Sparkle.
First-time installs (or anyone still on <= 0.3.0, which has no auto-update):
    curl -fsSL https://raw.githubusercontent.com/$REPO/main/script/install.sh | bash
MSG
