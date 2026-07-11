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
#   VERSION=0.6.0 script/notarize.sh
#
# Env overrides:
#   DEVELOPER_ID    full signing identity (default: first "Developer ID Application" in keychain)
#   NOTARY_PROFILE  notarytool keychain profile name (default: WhiskerFlow-Notary)
#   VERSION         release version (default: 0.6.0)
#   WHISKERFLOW_SENTRY_DSN  public DSN embedded in the packaged app
#   SENTRY_AUTH_TOKEN       release-only token used by sentry-cli
#   SENTRY_ORG / SENTRY_PROJECT  destination for dSYMs and release metadata
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT="WhiskerFlow"
VERSION="${VERSION:-0.6.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-WhiskerFlow-Notary}"
REPO="${REPO:-jw29247/WhiskerFlow}"
WHISKERFLOW_SENTRY_DSN="${WHISKERFLOW_SENTRY_DSN:-https://e933f92c9d1aeb052c5e27580575e46c@o4511347438583808.ingest.de.sentry.io/4511710099013712}"
export WHISKERFLOW_SENTRY_DSN

DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/$PRODUCT-$VERSION"
APP_BUNDLE="$STAGING_DIR/$PRODUCT.app"
APP_ZIP="$DIST_DIR/$PRODUCT-$VERSION-app.zip"
DMG_PATH="$DIST_DIR/$PRODUCT-$VERSION.dmg"
SPARKLE_ZIP="$DIST_DIR/$PRODUCT-$VERSION.zip"
DSYM_PATH="$DIST_DIR/$PRODUCT-$VERSION.dSYM"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/$PRODUCT-$VERSION.zip"

SENTRY_UPLOAD_ENABLED=true
if [[ -z "${SENTRY_AUTH_TOKEN:-}" || -z "${SENTRY_ORG:-}" || -z "${SENTRY_PROJECT:-}" ]]; then
  SENTRY_UPLOAD_ENABLED=false
  echo "==> Sentry credentials are not configured; retaining the dSYM locally without uploading it"
elif ! command -v sentry-cli >/dev/null 2>&1; then
  echo "ERROR: sentry-cli is required when Sentry release credentials are configured." >&2
  exit 1
fi

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Resources/Info.plist")"
if [[ "$PLIST_VERSION" != "$VERSION" ]]; then
  echo "ERROR: VERSION=$VERSION does not match Info.plist version $PLIST_VERSION." >&2
  exit 1
fi
SENTRY_RELEASE="agency.thatworks.WhiskerFlow@$VERSION+$BUILD_NUMBER"

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
rm -rf "$STAGING_DIR" "$APP_ZIP" "$DMG_PATH" "$SPARKLE_ZIP" "$DSYM_PATH"
mkdir -p "$STAGING_DIR"
export COPYFILE_DISABLE=1

# --- 1. Build + Developer ID sign (hardened runtime + entitlements) -----------
CONFIGURATION=release SIGN_IDENTITY="$SIGN_IDENTITY" \
  "$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null
echo "==> Built & signed $APP_BUNDLE"
xcrun dsymutil "$APP_BUNDLE/Contents/MacOS/$PRODUCT" -o "$DSYM_PATH"
APP_UUIDS="$(xcrun dwarfdump --uuid "$APP_BUNDLE/Contents/MacOS/$PRODUCT" | awk '{print $2}' | sort)"
DSYM_UUIDS="$(xcrun dwarfdump --uuid "$DSYM_PATH" | awk '{print $2}' | sort)"
if [[ -z "$APP_UUIDS" || "$APP_UUIDS" != "$DSYM_UUIDS" ]]; then
  echo "ERROR: Generated dSYM UUID does not match the release executable." >&2
  exit 1
fi
if strings "$DSYM_PATH/Contents/Resources/DWARF/$PRODUCT" | grep -F "$HOME/" >/dev/null; then
  echo "ERROR: Generated dSYM contains a local home-directory path." >&2
  exit 1
fi
echo "==> Generated matching dSYM at $DSYM_PATH"

# --- 2. Notarize the app and staple the ticket onto it (works offline) --------
ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
echo "==> Submitting app for notarization (a few minutes)…"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_BUNDLE"
rm -f "$APP_ZIP"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
echo "==> Notarized & stapled the app"

# --- 3. Stage DMG contents ----------------------------------------------------
cp "$ROOT_DIR/Distribution/README.txt" "$STAGING_DIR/README.txt"
cp "$ROOT_DIR/Distribution/Install Whisper.command" "$STAGING_DIR/Install Whisper.command"
chmod +x "$STAGING_DIR/Install Whisper.command"
ln -s /Applications "$STAGING_DIR/Applications"

# --- 4. Build, notarize, and staple the DMG (the artifact the team downloads) -
hdiutil create -volname "$PRODUCT $VERSION" -srcfolder "$STAGING_DIR" \
  -ov -format UDZO "$DMG_PATH" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
echo "==> Submitting DMG for notarization…"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
echo "==> Notarized & stapled $DMG_PATH"

# --- 4b. Sparkle update archive + appcast -------------------------------------
# Sparkle updates from a zipped copy of the *notarized, stapled* app (the ticket
# travels inside the zip, so Gatekeeper validates offline after the in-place
# swap). The enclosure URL points at the GitHub release asset uploaded below.
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

# --- 6. Publish symbolication data only after the signed artifacts validate --
if [[ "$SENTRY_UPLOAD_ENABLED" == true ]]; then
  sentry-cli --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    debug-files upload "$DSYM_PATH"
  sentry-cli --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    releases new "$SENTRY_RELEASE"
  sentry-cli --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    releases set-commits "$SENTRY_RELEASE" --auto
  sentry-cli --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" \
    releases finalize "$SENTRY_RELEASE"
  echo "==> Uploaded dSYM and finalized Sentry release $SENTRY_RELEASE"
else
  echo "==> Skipped Sentry upload; dSYM retained at $DSYM_PATH"
fi

cat <<MSG

==> Done.
    DMG (fresh installs):  $DMG_PATH
    ZIP (auto-update):     $SPARKLE_ZIP
    dSYM (Sentry):         $DSYM_PATH
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
