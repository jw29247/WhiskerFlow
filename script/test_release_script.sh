#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SCRIPT="$ROOT_DIR/script/notarize.sh"

create_line="$(grep -n 'hdiutil create' "$RELEASE_SCRIPT" | cut -d: -f1 || true)"
sign_line="$(grep -n 'codesign --force --timestamp --sign "\$SIGN_IDENTITY" "\$DMG_PATH"' "$RELEASE_SCRIPT" | cut -d: -f1 || true)"
submit_line="$(grep -n 'notarytool submit "\$DMG_PATH"' "$RELEASE_SCRIPT" | cut -d: -f1 || true)"

if [[ -z "$create_line" || -z "$sign_line" || -z "$submit_line" ]]; then
  echo "FAIL: release DMG must be created, Developer ID signed, then submitted for notarization" >&2
  exit 1
fi

if (( create_line >= sign_line || sign_line >= submit_line )); then
  echo "FAIL: release DMG signing must occur after creation and before notarization" >&2
  exit 1
fi

echo "PASS: release DMG is signed before notarization"
