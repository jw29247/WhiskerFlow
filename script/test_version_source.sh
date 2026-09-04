#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/script" "$TEST_ROOT/Resources"
cp "$ROOT_DIR/script/bump_version.sh" "$TEST_ROOT/script/"
cp "$ROOT_DIR/Resources/Info.plist" "$TEST_ROOT/Resources/"
PLIST="$TEST_ROOT/Resources/Info.plist"
OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

bash "$TEST_ROOT/script/bump_version.sh" 9.8.7 >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == 9.8.7 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")" == "$((OLD_BUILD + 1))" ]]
cp "$PLIST" "$TEST_ROOT/expected.plist"

for invalid in '' '1.2' 'not-a-version'; do
  if bash "$TEST_ROOT/script/bump_version.sh" "$invalid" >/dev/null 2>&1; then
    echo "FAIL: invalid version was accepted: $invalid" >&2
    exit 1
  fi
  cmp "$PLIST" "$TEST_ROOT/expected.plist"
done

if VERSION=99.98.97 bash "$ROOT_DIR/script/notarize.sh" >"$TEST_ROOT/release.log" 2>&1; then
  echo "FAIL: release accepted a version that disagrees with Info.plist" >&2
  exit 1
fi
grep -q 'does not match Info.plist version' "$TEST_ROOT/release.log"
echo "PASS: version bump increments the build; invalid versions leave the plist intact; release rejects version skew"
