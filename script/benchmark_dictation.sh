#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <manifest.json> <results.json>" >&2
  echo "Manifest: JSON array of objects with audioFilePath pointing to local saved audio." >&2
  exit 2
fi
# Results include transcript text for equality checks. Keep them local and ignored.
export WHISKERFLOW_BENCHMARK_MANIFEST="$1"
export WHISKERFLOW_BENCHMARK_OUTPUT="$2"
cd "$ROOT_DIR"
swift test -c release --filter DictationPerformanceTests
