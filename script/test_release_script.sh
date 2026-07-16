#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_SCRIPT="$ROOT_DIR/script/notarize.sh"
INSTALL_SCRIPT="$ROOT_DIR/script/install.sh"

create_line="$(grep -n 'hdiutil create' "$RELEASE_SCRIPT" | cut -d: -f1 || true)"
sign_line="$(grep -n 'codesign --force --timestamp --sign "\$SIGN_IDENTITY" "\$DMG_PATH"' "$RELEASE_SCRIPT" | cut -d: -f1 || true)"
submit_line="$(grep -n 'notarytool submit "\$DMG_PATH"' "$RELEASE_SCRIPT" | cut -d: -f1 || true)"
identity_line="$(grep -n 'verify_upgrade_identity.sh.*"\$APP_BUNDLE"' "$RELEASE_SCRIPT" | cut -d: -f1 || true)"

if [[ -z "$create_line" || -z "$sign_line" || -z "$submit_line" ]]; then
  echo "FAIL: release DMG must be created, Developer ID signed, then submitted for notarization" >&2
  exit 1
fi

if (( create_line >= sign_line || sign_line >= submit_line )); then
  echo "FAIL: release DMG signing must occur after creation and before notarization" >&2
  exit 1
fi

echo "PASS: release DMG is signed before notarization"

if [[ -z "$identity_line" || "$identity_line" -ge "$create_line" ]]; then
  echo "FAIL: release app must have the established Developer ID team before packaging" >&2
  exit 1
fi

echo "PASS: release app preserves the established Developer ID team"

verify_line="$(grep -n 'verify_upgrade_identity.sh' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1 || true)"
replace_line="$(grep -n 'rm -rf "/Applications/\$APP.app"' "$INSTALL_SCRIPT" | head -1 | cut -d: -f1 || true)"

if [[ -z "$verify_line" || -z "$replace_line" || "$verify_line" -ge "$replace_line" ]]; then
  echo "FAIL: installer must verify the candidate identity before replacing the installed app" >&2
  exit 1
fi

echo "PASS: installer verifies identity before replacing the installed app"
