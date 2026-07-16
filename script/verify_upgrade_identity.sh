#!/usr/bin/env bash
set -euo pipefail

EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-G9U38P58ZY}"
CODESIGN_BIN="${CODESIGN_BIN:-codesign}"
CANDIDATE_APP="${1:?usage: verify_upgrade_identity.sh CANDIDATE_APP [INSTALLED_APP]}"
INSTALLED_APP="${2:-}"

team_identifier() {
  "$CODESIGN_BIN" --display --verbose=4 "$1" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p' \
    | head -1
}

if [[ ! -d "$CANDIDATE_APP" ]]; then
  echo "Candidate app does not exist: $CANDIDATE_APP" >&2
  exit 1
fi

"$CODESIGN_BIN" --verify --deep --strict "$CANDIDATE_APP"

candidate_team="$(team_identifier "$CANDIDATE_APP")"
if [[ "$candidate_team" != "$EXPECTED_TEAM_ID" ]]; then
  echo "Refusing to install $CANDIDATE_APP." >&2
  echo "Expected Developer ID team $EXPECTED_TEAM_ID; found ${candidate_team:-no team (ad-hoc)}." >&2
  echo "Replacing the production app with this build would invalidate macOS permissions." >&2
  exit 1
fi

if [[ -n "$INSTALLED_APP" && -d "$INSTALLED_APP" ]]; then
  installed_team="$(team_identifier "$INSTALLED_APP")"
  if [[ -n "$installed_team" && "$installed_team" != "not set" && "$installed_team" != "$candidate_team" ]]; then
    echo "Refusing to replace an app signed by team $installed_team with team $candidate_team." >&2
    exit 1
  fi
fi

echo "Verified stable Developer ID team: $candidate_team"
