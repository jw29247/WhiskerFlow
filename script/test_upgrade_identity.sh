#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_SCRIPT="$ROOT_DIR/script/verify_upgrade_identity.sh"
FIXTURE_CODESIGN="$ROOT_DIR/Tests/Fixtures/fake_codesign.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for app in signed-current signed-candidate other-team adhoc; do
  mkdir -p "$TMP/$app.app"
done

run_verify() {
  CODESIGN_BIN="$FIXTURE_CODESIGN" EXPECTED_TEAM_ID="G9U38P58ZY" \
    bash "$VERIFY_SCRIPT" "$@"
}

run_verify "$TMP/signed-candidate.app" "$TMP/signed-current.app" >/dev/null

if run_verify "$TMP/adhoc.app" "$TMP/signed-current.app" >/dev/null 2>&1; then
  echo "FAIL: an ad-hoc candidate must not replace the production app" >&2
  exit 1
fi

if run_verify "$TMP/other-team.app" "$TMP/signed-current.app" >/dev/null 2>&1; then
  echo "FAIL: a candidate from a different team must not replace the production app" >&2
  exit 1
fi

run_verify "$TMP/signed-candidate.app" >/dev/null

echo "PASS: production upgrades preserve the Developer ID team identity"
