#!/usr/bin/env bash
# Renders every first-run setup screen from --ui-preview fixtures to PNGs.
# The app draws its own window, so no Screen Recording permission is needed.
#   script/onboarding_snapshots.sh [output-dir] [--ui-dark]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/.build/onboarding-snapshots}"
shift || true
# Its own bundle name and identifier: other preview runs match on
# "WhiskerFlow UI Preview.app" and must not stop this one.
APP_BUNDLE="$ROOT_DIR/.build/onboarding-preview/WhiskerFlow Onboarding Preview.app"
mkdir -p "$OUT_DIR"
CONFIGURATION=debug BUNDLE_IDENTIFIER_OVERRIDE=agency.thatworks.WhiskerFlow.onboarding-preview \
  BUNDLE_NAME_OVERRIDE="WhiskerFlow Onboarding Preview" "$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null
index=1
for step in welcome permissions microphone shortcut model practice extras done; do
  /usr/bin/open -n -W "$APP_BUNDLE" --args --ui-preview "--ui-state=onboarding-$step" \
    "--ui-snapshot=$OUT_DIR/$index-$step.png" "$@"
  index=$((index + 1))
done
echo "$OUT_DIR"
