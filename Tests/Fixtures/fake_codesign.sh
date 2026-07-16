#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--verify" ]]; then
  exit 0
fi

bundle="${@: -1}"
case "$bundle" in
  *signed-current.app|*signed-candidate.app)
    echo "TeamIdentifier=G9U38P58ZY" >&2
    ;;
  *other-team.app)
    echo "TeamIdentifier=OTHERTEAM1" >&2
    ;;
  *adhoc.app)
    echo "TeamIdentifier=not set" >&2
    ;;
  *)
    echo "TeamIdentifier=" >&2
    ;;
esac
