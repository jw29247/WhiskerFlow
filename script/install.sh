#!/usr/bin/env bash
set -euo pipefail

# One-line installer:
#   curl -fsSL https://raw.githubusercontent.com/jw29247/WhiskerFlow/main/script/install.sh | bash
#
# Override the source repo with WHISKERFLOW_REPO=owner/name.

REPO="${WHISKERFLOW_REPO:-jw29247/WhiskerFlow}"
APP="WhiskerFlow"

echo "Looking up the latest ${APP} release in ${REPO}..."
DMG_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -oE '"browser_download_url": *"[^"]+\.dmg"' \
  | head -1 \
  | sed -E 's/.*"(https[^"]+)"/\1/')

if [[ -z "${DMG_URL:-}" ]]; then
  echo "Could not find a .dmg in the latest release of $REPO." >&2
  echo "Build from source instead: swift run, or script/package_release.sh." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $DMG_URL"
curl -fSL "$DMG_URL" -o "$TMP/$APP.dmg"

MOUNT="$(hdiutil attach "$TMP/$APP.dmg" -nobrowse -readonly | grep -oE '/Volumes/[^ ]+.*' | tail -1)"
if [[ -z "${MOUNT:-}" || ! -d "$MOUNT/$APP.app" ]]; then
  echo "Failed to mount the disk image." >&2
  exit 1
fi

VERIFY_SCRIPT="$TMP/verify_upgrade_identity.sh"
curl -fsSL "https://raw.githubusercontent.com/$REPO/main/script/verify_upgrade_identity.sh" \
  -o "$VERIFY_SCRIPT"
bash "$VERIFY_SCRIPT" "$MOUNT/$APP.app" "/Applications/$APP.app"

echo "Installing to /Applications..."
rm -rf "/Applications/$APP.app"
cp -R "$MOUNT/$APP.app" /Applications/
hdiutil detach "$MOUNT" >/dev/null
xattr -dr com.apple.quarantine "/Applications/$APP.app" 2>/dev/null || true

echo "Installed. Open $APP from Applications, then grant Microphone + Accessibility."
