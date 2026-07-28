#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
BUMP_SCRIPT="$ROOT_DIR/script/bump_version.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
DERIVATION="PlistBuddy -c 'Print :CFBundleShortVersionString'"

for script in package_release.sh notarize.sh; do
  path="$ROOT_DIR/script/$script"

  if grep -q 'VERSION:-0\.' "$path"; then
    echo "FAIL: $script hardcodes a stale version default; derive it from Resources/Info.plist" >&2
    exit 1
  fi

  if ! grep -qF "$DERIVATION" "$path"; then
    echo "FAIL: $script must read the version from Resources/Info.plist via PlistBuddy" >&2
    exit 1
  fi
done

echo "PASS: release scripts derive the version from Resources/Info.plist"

if [[ ! -f "$BUMP_SCRIPT" ]]; then
  echo "FAIL: script/bump_version.sh must exist so the version is bumped in one place" >&2
  exit 1
fi

if [[ ! -x "$BUMP_SCRIPT" ]]; then
  echo "FAIL: script/bump_version.sh must be executable" >&2
  exit 1
fi

echo "PASS: script/bump_version.sh exists and is executable"

if ! grep -qF "$DERIVATION" "$WORKFLOW"; then
  echo "FAIL: release.yml must compare the tag against the Resources/Info.plist version" >&2
  exit 1
fi

echo "PASS: release.yml guards the tag against the Resources/Info.plist version"

[[ -f "$INFO_PLIST" ]] || { echo "FAIL: Resources/Info.plist not found" >&2; exit 1; }

echo "PASS: Resources/Info.plist is the single source of the version"
