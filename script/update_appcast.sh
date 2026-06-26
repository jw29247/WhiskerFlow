#!/usr/bin/env bash
#
# Sign a Sparkle update archive and add it to appcast.xml (newest first).
# Normally called by script/notarize.sh, but usable standalone:
#
#   ZIP=dist/WhiskerFlow-0.4.0.zip VERSION=0.4.0 BUILD=4 \
#   URL=https://github.com/jw29247/WhiskerFlow/releases/download/v0.4.0/WhiskerFlow-0.4.0.zip \
#   script/update_appcast.sh
#
# The EdDSA signature is produced by Sparkle's sign_update, which reads the
# private key from your login Keychain (see script/sparkle_keygen.sh).
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST="${APPCAST:-$ROOT_DIR/appcast.xml}"
SIGN_UPDATE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/sign_update"

ZIP="${ZIP:?set ZIP=path to the .zip archive}"
VERSION="${VERSION:?set VERSION=short version, e.g. 0.4.0}"
BUILD="${BUILD:?set BUILD=CFBundleVersion, e.g. 4}"
URL="${URL:?set URL=public download URL for the .zip}"
MIN_SYSTEM="${MIN_SYSTEM:-14.0}"
NOTES="${NOTES:-}"
# By default sign_update reads the private key from the login Keychain. Set
# ED_KEY_FILE to sign from an exported key file instead (e.g. a CI secret).
ED_KEY_FILE="${ED_KEY_FILE:-}"

[[ -f "$ZIP" ]] || { echo "ERROR: archive not found: $ZIP" >&2; exit 1; }
[[ -f "$APPCAST" ]] || { echo "ERROR: appcast not found: $APPCAST" >&2; exit 1; }
if [[ ! -x "$SIGN_UPDATE" ]]; then
  (cd "$ROOT_DIR" && swift package resolve >/dev/null)
fi
[[ -x "$SIGN_UPDATE" ]] || { echo "ERROR: sign_update not found at $SIGN_UPDATE" >&2; exit 1; }

if grep -q "sparkle:shortVersionString=\"$VERSION\"" "$APPCAST"; then
  echo "ERROR: appcast already contains version $VERSION — bump the version or remove the stale item." >&2
  exit 1
fi

# sign_update prints ready-to-use enclosure attributes: sparkle:edSignature="…" length="…"
if [[ -n "$ED_KEY_FILE" ]]; then
  SIGLEN="$("$SIGN_UPDATE" --ed-key-file "$ED_KEY_FILE" "$ZIP")"
else
  SIGLEN="$("$SIGN_UPDATE" "$ZIP")"
fi
PUBDATE="$(date -u "+%a, %d %b %Y %H:%M:%S +0000")"

DESC=""
[[ -n "$NOTES" ]] && DESC="
      <description><![CDATA[${NOTES}]]></description>"

ITEM_FILE="$(mktemp)"
cat > "$ITEM_FILE" <<ITEM
    <item>
      <title>${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:minimumSystemVersion>${MIN_SYSTEM}</sparkle:minimumSystemVersion>${DESC}
      <enclosure url="${URL}" sparkle:version="${BUILD}" sparkle:shortVersionString="${VERSION}" ${SIGLEN} type="application/octet-stream"/>
    </item>
ITEM

# Insert the new item directly after the RELEASES marker (keeps newest first).
TMP="$(mktemp)"
awk -v itemfile="$ITEM_FILE" '
  { print }
  /<!-- RELEASES/ && !done {
    while ((getline line < itemfile) > 0) print line
    close(itemfile)
    done = 1
  }
' "$APPCAST" > "$TMP"
mv "$TMP" "$APPCAST"
rm -f "$ITEM_FILE"

echo "==> Added $VERSION (build $BUILD) to $APPCAST"
echo "    url: $URL"
echo "    $SIGLEN"
