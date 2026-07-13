#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
PRODUCT="WhiskerFlow"
APP_BUNDLE="$ROOT_DIR/.build/$CONFIGURATION/$PRODUCT.app"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"

"$ROOT_DIR/script/bundle_app.sh" "$APP_BUNDLE" >/dev/null

shopt -s nullglob
resource_bundles=("$BUILD_DIR"/*.bundle)
shopt -u nullglob

if (( ${#resource_bundles[@]} == 0 )); then
  echo "FAIL: SwiftPM produced no resource bundles to verify" >&2
  exit 1
fi

if [[ ! -f "$APP_BUNDLE/Contents/Resources/WhiskerFlow_WhiskerFlow.bundle/shared-vocabulary.json" ]]; then
  echo "FAIL: packaged shared vocabulary seed is missing" >&2
  exit 1
fi

if grep -q 'Bundle\.module' "$ROOT_DIR/Sources/WhiskerFlow/Services/SharedVocabularyService.swift"; then
  echo "FAIL: packaged app resources must not use SwiftPM's Bundle.module accessor" >&2
  exit 1
fi

echo "PASS: packaged shared vocabulary is resolved without Bundle.module"
