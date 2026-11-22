#!/usr/bin/env bash
set -euo pipefail

# Runs script/verify_release_feed.sh against fake `gh` and `curl`, and pins the
# feed URL shipped builds read. Nothing here touches the network or GitHub.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="$ROOT_DIR/script/verify_release_feed.sh"
FEED_URL="https://github.com/jw29247/WhiskerFlow/releases/latest/download/appcast.xml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $1" >&2
  echo "--- output" >&2
  echo "${OUTPUT:-}" >&2
  echo "--- fake log" >&2
  cat "$LOG" >&2 2>/dev/null || true
  exit 1
}

# --- Shipped builds read the release-asset feed, and appcast.xml agrees.
plist_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$ROOT_DIR/Resources/Info.plist")"
[[ "$plist_url" == "$FEED_URL" ]] \
  || { echo "FAIL: SUFeedURL is '$plist_url', expected $FEED_URL" >&2; exit 1; }
grep -qF "<link>$FEED_URL</link>" "$ROOT_DIR/appcast.xml" \
  || { echo "FAIL: appcast.xml <link> is not $FEED_URL" >&2; exit 1; }

# --- Fakes. `gh release view` prints $FAKE_LISTING (the output of the real
# --jq filter: "draft <bool>", then "<name> <size>" per asset), or fails when
# FAKE_RELEASE_MISSING=1. `gh release download` copies $FAKE_ASSET_FEED to
# --output. `curl` copies $FAKE_PUBLIC_FEED to -o. Every call is logged.
FAKES="$TMP/fakes"
mkdir -p "$FAKES"
cat >"$FAKES/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE_LOG"
case "$1 ${2:-}" in
  "release view")
    [[ "${FAKE_RELEASE_MISSING:-0}" == 1 ]] && { echo "release not found" >&2; exit 1; }
    printf '%s\n' "$FAKE_LISTING"
    ;;
  "release download")
    out=""
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--output" ]] && out="$2"
      shift
    done
    [[ -n "$out" ]] || { echo "fake gh: no --output" >&2; exit 1; }
    cp "$FAKE_ASSET_FEED" "$out"
    ;;
  *)
    echo "fake gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
EOF
cat >"$FAKES/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$FAKE_LOG"
out=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "-o" ]] && out="$2"
  shift
done
[[ -n "$out" ]] || { echo "fake curl: no -o" >&2; exit 1; }
cp "$FAKE_PUBLIC_FEED" "$out"
EOF
chmod +x "$FAKES/gh" "$FAKES/curl"

VERSION="9.8.7"
ZIP_SIZE="12345"
GOOD_URL="https://github.com/jw29247/WhiskerFlow/releases/download/v$VERSION/WhiskerFlow-$VERSION.zip"

# write_feed <file> <top version> <enclosure url> <length> [signature]
write_feed() {
  local signature='sparkle:edSignature="c2lnbmF0dXJl"'
  [[ $# -ge 5 ]] && signature="$5"
  cat >"$1" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>WhiskerFlow</title>
    <link>$FEED_URL</link>
    <item>
      <title>$2</title>
      <enclosure url="$3" sparkle:version="40" sparkle:shortVersionString="$2" $signature length="$4" type="application/octet-stream"/>
    </item>
    <item>
      <title>1.0.0</title>
      <enclosure url="https://github.com/jw29247/WhiskerFlow/releases/download/v1.0.0/WhiskerFlow-1.0.0.zip" sparkle:version="1" sparkle:shortVersionString="1.0.0" sparkle:edSignature="b2xk" length="1" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
}

GOOD_FEED="$TMP/good.xml"
write_feed "$GOOD_FEED" "$VERSION" "$GOOD_URL" "$ZIP_SIZE"
GOOD_LISTING="draft true
WhiskerFlow-$VERSION.dmg 99999
WhiskerFlow-$VERSION.zip $ZIP_SIZE
appcast.xml 2048"
PUBLISHED_LISTING="${GOOD_LISTING/draft true/draft false}"

OUTPUT=""
LOG="$TMP/fake.log"

run_verify() {
  local status=0
  : >"$LOG"
  OUTPUT="$(env PATH="$FAKES:$PATH" FAKE_LOG="$LOG" \
    FAKE_LISTING="${LISTING:-$GOOD_LISTING}" FAKE_ASSET_FEED="${ASSET_FEED:-$GOOD_FEED}" \
    FAKE_PUBLIC_FEED="${PUBLIC_FEED:-$GOOD_FEED}" FAKE_RELEASE_MISSING="${MISSING:-0}" \
    bash "$VERIFY" "$@" 2>&1)" || status=$?
  return "$status"
}

expect_pass() {
  local label="$1"
  shift
  run_verify "$@" || fail "$label: verification failed"
  [[ "$OUTPUT" == *"PASS: release feed for $VERSION is correct"* ]] || fail "$label: no PASS line"
}

expect_failure() {
  local label="$1" message="$2"
  shift 2
  if run_verify "$@"; then
    fail "$label: verification passed"
  fi
  [[ "$OUTPUT" == *"FEED CHECK FAILED"* ]] || fail "$label: no failure banner"
  [[ "$OUTPUT" == *"$message"* ]] || fail "$label: expected message '$message'"
}

# A correct draft passes, reads the canonical repository and fetches the
# asset through gh, never the public URL.
expect_pass "correct draft" "$VERSION"
grep -q -- "release view v$VERSION --repo jw29247/WhiskerFlow " "$LOG" || fail "correct draft: wrong release or repository"
grep -q -- "release download v$VERSION --repo jw29247/WhiskerFlow --pattern appcast.xml" "$LOG" \
  || fail "correct draft: appcast.xml not fetched through gh"
grep -q '^curl' "$LOG" && fail "correct draft: public URL fetched without --published"

# REPO cannot redirect the check.
REPO=someone/fork expect_pass "REPO ignored" "$VERSION"
grep -q -- "--repo jw29247/WhiskerFlow " "$LOG" || fail "REPO ignored: repository overridden"

MISSING=1 expect_failure "missing release" "could not read release v$VERSION" "$VERSION"

LISTING="draft true
WhiskerFlow-$VERSION.dmg 99999
WhiskerFlow-$VERSION.zip $ZIP_SIZE" \
  expect_failure "missing appcast asset" "exactly these assets" "$VERSION"
grep -q 'release download' "$LOG" && fail "missing appcast asset: still downloaded"

LISTING="$GOOD_LISTING
notes.txt 10" expect_failure "extra asset" "exactly these assets" "$VERSION"

STALE="$TMP/stale.xml"
write_feed "$STALE" "9.8.6" "${GOOD_URL//$VERSION/9.8.6}" "$ZIP_SIZE"
ASSET_FEED="$STALE" expect_failure "wrong top version" "first <item> in appcast.xml is '9.8.6', not $VERSION" "$VERSION"

OTHER_URL="$TMP/other-url.xml"
write_feed "$OTHER_URL" "$VERSION" "${GOOD_URL//v$VERSION/v9.8.6}" "$ZIP_SIZE"
ASSET_FEED="$OTHER_URL" expect_failure "enclosure for another version" "enclosure URL is wrong" "$VERSION"

UNSIGNED="$TMP/unsigned.xml"
write_feed "$UNSIGNED" "$VERSION" "$GOOD_URL" "$ZIP_SIZE" ""
ASSET_FEED="$UNSIGNED" expect_failure "unsigned enclosure" "no sparkle:edSignature" "$VERSION"

WRONG_LENGTH="$TMP/wrong-length.xml"
write_feed "$WRONG_LENGTH" "$VERSION" "$GOOD_URL" "54321"
ASSET_FEED="$WRONG_LENGTH" expect_failure "length mismatch" "enclosure length (54321) does not match" "$VERSION"

MALFORMED="$TMP/malformed.xml"
head -n 8 "$GOOD_FEED" >"$MALFORMED"
ASSET_FEED="$MALFORMED" expect_failure "malformed XML" "not well-formed XML" "$VERSION"

# --published: the release must be public and the public feed must match.
LISTING="$PUBLISHED_LISTING" expect_pass "published" --published "$VERSION"
grep -qF "curl -fsSL --retry 2 -o" "$LOG" || fail "published: public feed not fetched"
grep -qF "$FEED_URL" "$LOG" || fail "published: wrong public feed URL"

LISTING="$PUBLISHED_LISTING" PUBLIC_FEED="$STALE" \
  expect_failure "published, public feed differs" "does not serve this release's appcast.xml" --published "$VERSION"

expect_failure "published, still a draft" "still a draft" --published "$VERSION"

# Bad arguments are usage errors.
for args in "" "2.1" "--bogus $VERSION" "$VERSION 1.0.0"; do
  # shellcheck disable=SC2086
  if run_verify $args; then
    fail "bad arguments '$args' accepted"
  fi
done

echo "PASS: SUFeedURL is the release-asset feed; verify_release_feed.sh catches missing, stale, mismatched and malformed release feeds"
