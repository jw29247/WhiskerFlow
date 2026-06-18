#!/usr/bin/env bash
#
# One-command signed + notarized release for sharing with the team.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in your login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + Developer ID Application).
#   2. Stored notary credentials under a keychain profile, e.g.:
#        xcrun notarytool store-credentials "WhiskerFlow-Notary" \
#          --apple-id "you@example.com" --team-id "DR37YKTXWX" \
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
VERSION="${VERSION:-0.3.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-WhiskerFlow-Notary}"
REPO="${REPO:-jw29247/WhiskerFlow}"

DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/$PRODUCT-$VERSION"
APP_BUNDLE="$STAGING_DIR/$PRODUCT.app"
APP_ZIP="$DIST_DIR/$PRODUCT-$VERSION-app.zip"
DMG_PATH="$DIST_DIR/$PRODUCT-$VERSION.dmg"

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

# --- 5. Update the Homebrew cask with the real version + checksum -------------
SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
CASK="$ROOT_DIR/Casks/whiskerflow.rb"
/usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
/usr/bin/sed -i '' -E "s/^  sha256 .*/  sha256 \"$SHA\"/" "$CASK"

cat <<MSG

==> Done.
    DMG:    $DMG_PATH
    sha256: $SHA
    Cask:   $CASK (version + sha256 updated)

Publish the release, then commit the updated cask:
    gh release create "v$VERSION" "$DMG_PATH" \\
      --repo "$REPO" --title "$PRODUCT $VERSION" --notes "Live transcription release"
    git commit -am "release: $PRODUCT $VERSION" && git push

Your team installs (or upgrades) with:
    brew install --cask "https://raw.githubusercontent.com/$REPO/main/Casks/whiskerflow.rb"
MSG
