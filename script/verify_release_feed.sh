#!/usr/bin/env bash
#
# Verify that GitHub release v<version> carries a correct Sparkle update feed
# before (and after) it goes live. Builds read their feed from
#   https://github.com/jw29247/WhiskerFlow/releases/latest/download/appcast.xml
# so publishing a release without a correct appcast.xml asset breaks updates
# for every build on that URL.
#
# Usage:
#   script/verify_release_feed.sh <version>              # on the draft, before publishing
#   script/verify_release_feed.sh --published <version>  # after publishing
#
# Checks:
#   - release v<version> exists with exactly three assets:
#     WhiskerFlow-<version>.dmg, WhiskerFlow-<version>.zip and appcast.xml;
#   - the appcast.xml asset is well-formed XML whose first <item> is <version>,
#     carries an edSignature, and whose enclosure URL is this release's .zip;
#   - the enclosure length equals the .zip asset size GitHub reports.
# With --published, additionally:
#   - the release is no longer a draft, and the public latest-release feed URL
#     serves the same file.
#
# Assets are fetched through `gh`, because a draft's asset URLs are not public.
# `gh` and `curl` are resolved from PATH so script/test_release_feed.sh can
# substitute fakes. The repository is fixed, as in script/require_green_ci.sh,
# so no environment setting can point the check elsewhere.
#
set -euo pipefail

REPO="jw29247/WhiskerFlow"
PRODUCT="WhiskerFlow"
PUBLIC_FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

usage() {
  echo "Usage: script/verify_release_feed.sh [--published] <version>" >&2
  exit 2
}

PUBLISHED=false
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --published) PUBLISHED=true ;;
    -*) usage ;;
    *) [[ -z "$VERSION" ]] || usage; VERSION="$arg" ;;
  esac
done
[[ -n "$VERSION" ]] || usage
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: version must look like 2.1.1, got '$VERSION'." >&2
  exit 2
fi

TAG="v$VERSION"
DMG="$PRODUCT-$VERSION.dmg"
ZIP="$PRODUCT-$VERSION.zip"
EXPECTED_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP"

fail() {
  {
    echo
    echo "FEED CHECK FAILED for $REPO $TAG: $1"
    if [[ $# -gt 1 ]]; then
      echo
      echo "$2"
    fi
    echo
    echo "Do not publish this release (or, if already published, fix it now):"
    echo "builds read their updates from $PUBLIC_FEED_URL."
  } >&2
  exit 1
}

for tool in gh curl xmllint; do
  command -v "$tool" >/dev/null 2>&1 || fail "'$tool' is not installed."
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. The release and its assets. One "draft <bool>" line, then one
#        "<name> <size>" line per asset.
if ! listing="$(gh release view "$TAG" --repo "$REPO" --json isDraft,assets \
  --jq '"draft \(.isDraft)", (.assets[] | "\(.name) \(.size)")' 2>&1)"; then
  fail "could not read release $TAG." "gh said:
$listing

Create it first as a draft (gh release create … --draft), or check \`gh auth status\`."
fi

is_draft=""
zip_size=""
names=()
while read -r name size; do
  [[ -z "${name:-}" ]] && continue
  if [[ "$name" == "draft" ]]; then
    is_draft="$size"
    continue
  fi
  names+=("$name")
  [[ "$name" == "$ZIP" ]] && zip_size="$size"
done <<<"$listing"

actual_assets="$(printf '%s\n' "${names[@]+"${names[@]}"}" | sort)"
expected_assets="$(printf '%s\n' "$DMG" "$ZIP" appcast.xml | sort)"
if [[ "$actual_assets" != "$expected_assets" ]]; then
  fail "the release must have exactly these assets: $DMG, $ZIP, appcast.xml." "It has:
${actual_assets:-  (none)}

Upload a missing asset with: gh release upload $TAG <file> --repo $REPO"
fi

# --- 2. The appcast.xml asset itself.
FEED="$TMP/appcast.xml"
if ! out="$(gh release download "$TAG" --repo "$REPO" --pattern appcast.xml --output "$FEED" 2>&1)" \
  || [[ ! -s "$FEED" ]]; then
  fail "could not download the release's appcast.xml asset." "gh said:
$out"
fi

if ! xml_errors="$(xmllint --noout "$FEED" 2>&1)"; then
  fail "the release's appcast.xml is not well-formed XML." "$xml_errors"
fi

first_item() {
  xmllint --xpath "string((//*[local-name()='item'])[1]/*[local-name()='enclosure']/@*[local-name()='$1'])" "$FEED" 2>/dev/null || true
}
top_version="$(first_item shortVersionString)"
signature="$(first_item edSignature)"
enclosure_url="$(first_item url)"
enclosure_length="$(first_item length)"

[[ "$top_version" == "$VERSION" ]] \
  || fail "the first <item> in appcast.xml is '${top_version:-(none)}', not $VERSION." \
    "Upload the appcast.xml that notarize.sh generated for $VERSION:
  gh release upload $TAG appcast.xml --clobber --repo $REPO"
[[ -n "$signature" ]] \
  || fail "the $VERSION enclosure has no sparkle:edSignature, so Sparkle would reject the update."
[[ "$enclosure_url" == "$EXPECTED_URL" ]] \
  || fail "the $VERSION enclosure URL is wrong." "Expected: $EXPECTED_URL
Found:    ${enclosure_url:-(none)}"
[[ -n "$zip_size" && "$enclosure_length" == "$zip_size" ]] \
  || fail "the $VERSION enclosure length (${enclosure_length:-none}) does not match the size of $ZIP on GitHub (${zip_size:-unknown})." \
    "The uploaded .zip is not the archive that was signed into appcast.xml."

echo "==> Release $TAG has $DMG, $ZIP and appcast.xml (draft: ${is_draft:-unknown})"
echo "==> appcast.xml: $VERSION is first, signed, enclosure $EXPECTED_URL ($zip_size bytes)"

# --- 3. After publishing: the public feed URL serves this file.
if [[ "$PUBLISHED" == true ]]; then
  [[ "$is_draft" == "false" ]] \
    || fail "--published was given but the release is still a draft." \
      "Publish it with: gh release edit $TAG --draft=false --latest --repo $REPO"
  PUBLIC="$TMP/public-appcast.xml"
  if ! out="$(curl -fsSL --retry 2 -o "$PUBLIC" "$PUBLIC_FEED_URL" 2>&1)"; then
    fail "could not fetch the public feed $PUBLIC_FEED_URL." "curl said:
$out"
  fi
  cmp -s "$FEED" "$PUBLIC" \
    || fail "the public feed $PUBLIC_FEED_URL does not serve this release's appcast.xml." \
      "Another release is probably marked latest. Mark this one: gh release edit $TAG --latest --repo $REPO"
  echo "==> $PUBLIC_FEED_URL serves this release's appcast.xml"
fi

echo "PASS: release feed for $VERSION is correct"
