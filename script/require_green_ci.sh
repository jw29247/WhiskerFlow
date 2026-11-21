#!/usr/bin/env bash
#
# Release gate: refuses unless the exact commit being released (HEAD of this
# checkout) has a completed, successful run of the CI workflow
# (.github/workflows/ci.yml) on GitHub, and the checkout matches it: no
# uncommitted changes and no untracked files.
#
# Called first thing by script/notarize.sh. `gh` is resolved from PATH so
# script/test_release_gate.sh can substitute a fake.
#
# Usage:
#   script/require_green_ci.sh
#
# The repository is fixed so no environment setting can point the check at a
# fork or another repository with different CI results.
#
# Emergency override (the only way to skip the gate):
#   ALLOW_UNVERIFIED_RELEASE=1
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="jw29247/WhiskerFlow"
CI_WORKFLOW="ci.yml"

refuse() {
  {
    echo
    echo "RELEASE BLOCKED: $1"
    echo
    cat
    echo
    echo "Emergency only: ALLOW_UNVERIFIED_RELEASE=1 skips this check."
  } >&2
  exit 1
}

if [[ "${ALLOW_UNVERIFIED_RELEASE:-}" == "1" ]]; then
  head_sha="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  cat >&2 <<MSG

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!! WARNING: ALLOW_UNVERIFIED_RELEASE=1 — SKIPPING THE GREEN-CI RELEASE GATE.
!! Commit $head_sha has NOT been checked against CI, and
!! uncommitted changes (if any) will be built and shipped to every user.
!! Use this only in an emergency, and say so in the release notes.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

MSG
  exit 0
fi

if ! head_sha="$(git -C "$ROOT_DIR" rev-parse --verify HEAD 2>/dev/null)"; then
  refuse "$ROOT_DIR is not a git checkout with a commit." <<'MSG'
Release from a clone of the repository, on the commit CI has verified.
MSG
fi

# 1. The build must match the verified commit: no tracked-file changes, staged
#    or not, and no untracked files. SwiftPM builds every source file it finds
#    under a target's directory, so an untracked file would be signed and
#    shipped without ever having been through CI. Ignored paths (.build, dist)
#    do not count.
dirty="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)"
if [[ -n "$dirty" ]]; then
  refuse "the checkout has uncommitted changes or untracked files, so the build would not match commit ${head_sha:0:12}." <<MSG
$dirty

Commit these, push them and wait for CI to pass on the new commit, or remove
them (git restore <file>; delete untracked files). If these are appcast.xml /
the cask from an earlier interrupted notarize.sh run, restore them and re-run.
MSG
fi

# 2. HEAD must have a completed, successful CI run on GitHub.
if ! command -v gh >/dev/null 2>&1; then
  refuse "the GitHub CLI (gh) is not installed, so CI status cannot be checked." <<'MSG'
Install it (brew install gh), run `gh auth login`, then re-run.
MSG
fi

if ! gh auth status >/dev/null 2>&1; then
  refuse "the GitHub CLI (gh) is not authenticated, so CI status cannot be checked." <<'MSG'
Run `gh auth login` (or set GH_TOKEN), then re-run.
MSG
fi

# One line per CI run for this exact SHA: status, conclusion, URL.
# Pull-request runs report the PR head SHA, so an open PR's checks count.
if ! runs="$(gh run list --repo "$REPO" --workflow "$CI_WORKFLOW" --commit "$head_sha" \
  --limit 50 --json status,conclusion,url \
  --jq '.[] | [.status, (if .conclusion == "" or .conclusion == null then "none" else .conclusion end), .url] | join(" ")' 2>&1)"; then
  refuse "could not query CI runs for $head_sha on $REPO." <<MSG
gh said:
$runs

Check your network and \`gh auth status\`, then re-run.
MSG
fi

success_url=""
pending=""
failed=""
while read -r status conclusion url; do
  [[ -z "${status:-}" ]] && continue
  if [[ "$status" == "completed" ]]; then
    if [[ "$conclusion" == "success" ]]; then
      success_url="$url"
    else
      failed+="  $conclusion: $url"$'\n'
    fi
  else
    pending+="  $status: $url"$'\n'
  fi
done <<<"$runs"

if [[ -n "$success_url" ]]; then
  echo "==> CI passed for $head_sha: $success_url"
  exit 0
fi

if [[ -n "$pending" ]]; then
  refuse "CI is still running for $head_sha." <<MSG
${pending}${failed:+Earlier runs on this commit did not pass:
$failed}
Wait for it to finish successfully (gh run watch), then re-run.
MSG
fi

if [[ -n "$failed" ]]; then
  refuse "CI did not pass for $head_sha (failed or cancelled)." <<MSG
$failed
Fix the problem, push a new commit, wait for CI to pass on it, then release that
commit. A cancelled run can be re-run with: gh run rerun <run-id>
MSG
fi

refuse "no CI run exists on $REPO for $head_sha." <<'MSG'
The commit has probably not been pushed. Push the release branch, open a pull
request against main, wait for CI to pass on this exact commit, then re-run.
MSG
