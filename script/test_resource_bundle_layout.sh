#!/usr/bin/env bash
# Checks resource_bundle_file against fake bundles of both SwiftPM layouts, so
# the packaging test is known to work on toolchains other than this machine's.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/resource_bundle.sh
source "$ROOT_DIR/script/lib/resource_bundle.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

flat="$TMP/flat/Example_Example.bundle"
mkdir -p "$flat"
echo flat > "$flat/Notices.txt"
[[ "$(resource_bundle_file "$flat" Notices.txt)" == "$flat/Notices.txt" ]]

nested="$TMP/nested/Example_Example.bundle"
mkdir -p "$nested/Contents/Resources"
echo nested > "$nested/Contents/Resources/Notices.txt"
[[ "$(resource_bundle_file "$nested" Notices.txt)" == "$nested/Contents/Resources/Notices.txt" ]]

empty="$TMP/empty/Example_Example.bundle"
mkdir -p "$empty/Contents/Resources"
if resource_bundle_file "$empty" Notices.txt 2>/dev/null; then
  echo "FAIL: a missing resource was found" >&2
  exit 1
fi

echo "PASS: resource bundle lookup handles flat and Contents/Resources layouts"
