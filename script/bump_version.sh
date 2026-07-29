#!/usr/bin/env bash
#
# Set the release version in Resources/Info.plist, the single source of truth
# for the version everything else (Sparkle, notarize.sh, appcast, cask) reads.
# CFBundleVersion is incremented automatically; Sparkle requires it to increase
# on every release.
#
#   script/bump_version.sh 0.6.3
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
PLIST_BUDDY=/usr/libexec/PlistBuddy

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: script/bump_version.sh <version>   e.g. script/bump_version.sh 0.6.3" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: version must look like x.y.z (got '$VERSION')." >&2
  exit 1
fi
[[ -f "$INFO_PLIST" ]] || { echo "ERROR: Info.plist not found: $INFO_PLIST" >&2; exit 1; }

OLD_VERSION="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
OLD_BUILD="$("$PLIST_BUDDY" -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ ! "$OLD_BUILD" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CFBundleVersion '$OLD_BUILD' is not an integer; cannot increment it." >&2
  exit 1
fi
NEW_BUILD=$((OLD_BUILD + 1))

"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"

echo "==> $OLD_VERSION (build $OLD_BUILD) -> $VERSION (build $NEW_BUILD) in $INFO_PLIST"
