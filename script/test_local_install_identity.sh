#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/script/install_app.sh"
BUNDLE_SCRIPT="$ROOT_DIR/script/bundle_app.sh"
RUN_SCRIPT="$ROOT_DIR/script/build_and_run.sh"

grep -q 'INSTALL_DIR="${INSTALL_DIR:-$ROOT_DIR/.build/local-apps}"' "$INSTALL_SCRIPT" || {
  echo "FAIL: local installs must stay out of Applications by default" >&2
  exit 1
}

grep -q 'BUNDLE_IDENTIFIER_OVERRIDE="agency.thatworks.WhiskerFlow.dev"' "$INSTALL_SCRIPT" || {
  echo "FAIL: local installs must use a separate development bundle identity" >&2
  exit 1
}

grep -q 'BUNDLE_IDENTIFIER_OVERRIDE="agency.thatworks.WhiskerFlow.dev"' "$RUN_SCRIPT" || {
  echo "FAIL: local run builds must not impersonate the production bundle identity" >&2
  exit 1
}

grep -q 'BUNDLE_IDENTIFIER_OVERRIDE' "$BUNDLE_SCRIPT" || {
  echo "FAIL: bundling must support a development bundle identity override" >&2
  exit 1
}

echo "PASS: local builds are isolated from production permissions and Applications"
