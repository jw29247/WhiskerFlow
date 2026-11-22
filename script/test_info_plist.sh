#!/usr/bin/env bash
# Resources/Info.plist is copied into the bundle as is: nothing substitutes
# Xcode build settings, so a "$(…)" placeholder would ship literally.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT_DIR/Resources/Info.plist"

if grep -nE '\$\(|\$\{' "$PLIST"; then
  echo "FAIL: Info.plist contains an unsubstituted build-setting placeholder" >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDevelopmentRegion' "$PLIST")" == en ]]
echo "Info.plist placeholder test passed"
