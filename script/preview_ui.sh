#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/.build/ui-preview/WhiskerFlow UI Preview.app"
# A distinct debug bundle: no production process is stopped or replaced.
CONFIGURATION=debug BUNDLE_IDENTIFIER_OVERRIDE=agency.thatworks.WhiskerFlow.ui-preview \
  BUNDLE_NAME_OVERRIDE="WhiskerFlow UI Preview" "$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE"
/usr/bin/open -n "$APP_BUNDLE" --args --ui-preview "$@"
