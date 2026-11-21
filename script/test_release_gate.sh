#!/usr/bin/env bash
set -euo pipefail

# Runs script/require_green_ci.sh in a throwaway git repository against a fake
# `gh`. Nothing here touches the network, GitHub or the real checkout.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_SCRIPT="$ROOT_DIR/script/require_green_ci.sh"
NOTARIZE_SCRIPT="$ROOT_DIR/script/notarize.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A minimal repository holding a copy of the gate, so `git status` and
# `git rev-parse HEAD` describe a commit we control.
REPO_DIR="$TMP/repo"
mkdir -p "$REPO_DIR/script"
cp "$GATE_SCRIPT" "$REPO_DIR/script/"
echo "tracked" >"$REPO_DIR/tracked.txt"
printf '.build/\ndist/\n' >"$REPO_DIR/.gitignore"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" -c user.name=test -c user.email=test@example.invalid \
  -c commit.gpgsign=false commit -q -m initial
HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"

# Fake gh. `auth status` succeeds unless FAKE_GH_AUTH=0. `run list` logs its
# arguments and prints $FAKE_GH_RUNS, which stands in for the output of the
# real --jq filter: one "status conclusion url" line per run.
FAKES="$TMP/fakes"
mkdir -p "$FAKES"
cat >"$FAKES/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$FAKE_LOG"
case "$1 ${2:-}" in
  "auth status")
    [[ "${FAKE_GH_AUTH:-1}" == "1" ]] || { echo "not logged in" >&2; exit 1; }
    ;;
  "run list")
    printf '%s' "${FAKE_GH_RUNS:-}"
    ;;
  *)
    echo "fake gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKES/gh"

# A PATH with the tools the gate needs but no gh at all.
NO_GH="$TMP/no-gh"
mkdir -p "$NO_GH"
for tool in git cat dirname; do
  ln -s "$(command -v "$tool")" "$NO_GH/$tool"
done

OUTPUT=""
LOG="$TMP/gh.log"

run_gate() {
  local status=0
  : >"$LOG"
  OUTPUT="$(env PATH="$FAKES:$PATH" FAKE_LOG="$LOG" "$@" \
    bash "$REPO_DIR/script/require_green_ci.sh" 2>&1)" || status=$?
  return "$status"
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- gate output" >&2
  echo "$OUTPUT" >&2
  echo "--- fake gh log" >&2
  cat "$LOG" >&2
  exit 1
}

expect_pass() {
  local label="$1"
  shift
  run_gate "$@" || fail "$label: gate refused"
}

expect_refusal() {
  local label="$1" message="$2"
  shift 2
  if run_gate "$@"; then
    fail "$label: gate passed"
  fi
  [[ "$OUTPUT" == *"RELEASE BLOCKED"* ]] || fail "$label: no refusal banner"
  [[ "$OUTPUT" == *"$message"* ]] || fail "$label: expected message '$message'"
  [[ "$OUTPUT" == *"ALLOW_UNVERIFIED_RELEASE=1"* ]] || fail "$label: override not documented"
}

URL="https://github.com/jw29247/WhiskerFlow/actions/runs/1"

# Green run on HEAD passes, and the query targets the CI workflow, this exact
# SHA and the canonical repository.
expect_pass "green run" FAKE_GH_RUNS="completed success $URL"
[[ "$OUTPUT" == *"CI passed for $HEAD_SHA"* ]] || fail "green run: no confirmation"
grep -q -- "--repo jw29247/WhiskerFlow " "$LOG" || fail "green run: wrong repository"
grep -q -- "--workflow ci.yml " "$LOG" || fail "green run: wrong workflow"
grep -q -- "--commit $HEAD_SHA " "$LOG" || fail "green run: did not query HEAD's SHA"

# A re-run that succeeded after a failure still counts as green.
expect_pass "green re-run" FAKE_GH_RUNS="completed success $URL
completed failure $URL"

# REPO cannot redirect the check.
expect_pass "REPO ignored" REPO=someone/fork FAKE_GH_RUNS="completed success $URL"
grep -q -- "--repo jw29247/WhiskerFlow " "$LOG" || fail "REPO ignored: repository overridden"

expect_refusal "no run" "no CI run exists" FAKE_GH_RUNS=""
[[ "$OUTPUT" == *"not been pushed"* ]] || fail "no run: no push hint"

expect_refusal "in progress" "CI is still running" FAKE_GH_RUNS="in_progress none $URL"
expect_refusal "queued" "CI is still running" FAKE_GH_RUNS="queued none $URL"
expect_refusal "failed" "CI did not pass" FAKE_GH_RUNS="completed failure $URL"
[[ "$OUTPUT" == *"failure: $URL"* ]] || fail "failed: run not reported"
expect_refusal "cancelled" "CI did not pass" FAKE_GH_RUNS="completed cancelled $URL"
[[ "$OUTPUT" == *"cancelled: $URL"* ]] || fail "cancelled: run not reported"

expect_refusal "unauthenticated gh" "not authenticated" \
  FAKE_GH_AUTH=0 FAKE_GH_RUNS="completed success $URL"
grep -q "run list" "$LOG" && fail "unauthenticated gh: still queried runs"

# Missing gh: run with a PATH that has no gh on it.
: >"$LOG"
status=0
OUTPUT="$(env PATH="$NO_GH" /bin/bash "$REPO_DIR/script/require_green_ci.sh" 2>&1)" || status=$?
[[ "$status" != 0 ]] || fail "missing gh: gate passed"
[[ "$OUTPUT" == *"not installed"* ]] || fail "missing gh: no clear message"

# Failing gh query (for example no network) refuses.
mkdir -p "$TMP/broken"
cat >"$TMP/broken/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "auth" ]] && exit 0
echo "error connecting to api.github.com" >&2
exit 1
EOF
chmod +x "$TMP/broken/gh"
status=0
OUTPUT="$(env PATH="$TMP/broken:$PATH" bash "$REPO_DIR/script/require_green_ci.sh" 2>&1)" || status=$?
[[ "$status" != 0 ]] || fail "gh query error: gate passed"
[[ "$OUTPUT" == *"could not query CI runs"* ]] || fail "gh query error: no clear message"

# Dirty tracked file refuses even with a green run, before asking GitHub.
echo "changed" >>"$REPO_DIR/tracked.txt"
expect_refusal "dirty tree" "uncommitted changes" FAKE_GH_RUNS="completed success $URL"
[[ "$OUTPUT" == *"tracked.txt"* ]] || fail "dirty tree: changed file not listed"
[[ -s "$LOG" ]] && fail "dirty tree: gh was consulted"

# Staged changes count too.
git -C "$REPO_DIR" add tracked.txt
expect_refusal "staged change" "uncommitted changes" FAKE_GH_RUNS="completed success $URL"
git -C "$REPO_DIR" reset -q --hard

# An untracked file refuses too: SwiftPM would compile an untracked source file
# that CI never saw.
mkdir -p "$REPO_DIR/Sources/App"
touch "$REPO_DIR/Sources/App/Untracked.swift"
expect_refusal "untracked file" "untracked files" FAKE_GH_RUNS="completed success $URL"
[[ "$OUTPUT" == *"Sources/"* ]] || fail "untracked file: path not listed"
[[ -s "$LOG" ]] && fail "untracked file: gh was consulted"
rm -r "$REPO_DIR/Sources"

# Ignored build output (.build, dist) does not block.
mkdir -p "$REPO_DIR/dist"
touch "$REPO_DIR/dist/WhiskerFlow.zip"
expect_pass "ignored build output" FAKE_GH_RUNS="completed success $URL"
rm -r "$REPO_DIR/dist"

# The override passes, loudly, even with no CI run, a dirty tree and no gh.
echo "changed" >>"$REPO_DIR/tracked.txt"
expect_pass "override" ALLOW_UNVERIFIED_RELEASE=1 FAKE_GH_RUNS=""
[[ "$OUTPUT" == *"WARNING: ALLOW_UNVERIFIED_RELEASE=1"* ]] || fail "override: no warning"
[[ -s "$LOG" ]] && fail "override: gh was consulted"
git -C "$REPO_DIR" reset -q --hard

# Only the exact value 1 overrides.
expect_refusal "override=true" "no CI run exists" ALLOW_UNVERIFIED_RELEASE=true FAKE_GH_RUNS=""

# notarize.sh runs the gate before resolving the signing identity or deleting
# anything, and does not pass it a repository.
gate_line="$(grep -n 'script/require_green_ci.sh"$' "$NOTARIZE_SCRIPT" | head -1 | cut -d: -f1)"
[[ -n "$gate_line" ]] || fail "notarize.sh does not call the release gate"
for marker in 'security find-identity' 'rm -rf' 'bundle_app.sh' 'PlistBuddy'; do
  marker_line="$(grep -n -F "$marker" "$NOTARIZE_SCRIPT" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)"
  [[ -n "$marker_line" && "$gate_line" -lt "$marker_line" ]] \
    || fail "notarize.sh reaches '$marker' before the release gate"
done

echo "PASS: release gate requires green CI on a clean HEAD; only ALLOW_UNVERIFIED_RELEASE=1 skips it"
