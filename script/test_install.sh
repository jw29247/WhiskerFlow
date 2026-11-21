#!/usr/bin/env bash
set -euo pipefail

# Runs script/install.sh against temporary directories and fake system tools.
# Nothing here touches the network, /Applications or a real running app.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="$ROOT_DIR/script/install.sh"
VERIFY_SCRIPT="$ROOT_DIR/script/verify_upgrade_identity.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKES="$TMP/fakes"
mkdir -p "$FAKES/bin"

# Each fake appends what it was asked to do to $FAKE_LOG.

# hdiutil: "attaches" by copying $FAKE_DMG_APP to the requested mount point.
cat >"$FAKES/hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "hdiutil $*" >>"$FAKE_LOG"
case "$1" in
  attach)
    mountpoint=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-mountpoint" ]]; then mountpoint="$2"; fi
      shift
    done
    cp -R "$FAKE_DMG_APP" "$mountpoint/"
    echo "attached $mountpoint" >>"$FAKE_STATE/mounts"
    ;;
  detach)
    rm -rf "${2:?}"/*
    echo "detached $2" >>"$FAKE_STATE/mounts"
    ;;
esac
EOF

# spctl: accepts unless FAKE_SPCTL_REJECT=1.
cat >"$FAKES/spctl" <<'EOF'
#!/usr/bin/env bash
echo "spctl $*" >>"$FAKE_LOG"
if [[ "${FAKE_SPCTL_REJECT:-0}" == "1" ]]; then
  echo "${@: -1}: rejected" >&2
  exit 3
fi
echo "${@: -1}: accepted"
EOF

# codesign: reports the team written in the bundle's Contents/team file.
cat >"$FAKES/codesign" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--verify" ]]; then
  exit 0
fi
bundle="${@: -1}"
echo "TeamIdentifier=$(cat "$bundle/Contents/team" 2>/dev/null)" >&2
EOF

# osascript: models WhiskerFlow's process. $FAKE_STATE/running holds 1 or 0.
# A quit request clears it only when FAKE_APP_QUITS=1.
cat >"$FAKES/osascript" <<'EOF'
#!/usr/bin/env bash
script="${@: -1}"
case "$script" in
  *forceTerminate*)
    echo "osascript force-terminate" >>"$FAKE_LOG"
    exit 0
    ;;
  *terminate*)
    echo "osascript terminate" >>"$FAKE_LOG"
    if [[ "${FAKE_APP_QUITS:-0}" == "1" ]]; then
      echo 0 >"$FAKE_STATE/running"
    fi
    ;;
  *.count)
    cat "$FAKE_STATE/running"
    ;;
  *)
    echo "osascript unexpected: $script" >>"$FAKE_LOG"
    exit 1
    ;;
esac
EOF

cat >"$FAKES/open" <<'EOF'
#!/usr/bin/env bash
echo "open $*" >>"$FAKE_LOG"
EOF

# PATH fakes catch the tools the installer must never call.
for tool in xattr kill pkill killall curl; do
  cat >"$FAKES/bin/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >>"\$FAKE_LOG"
exit 1
EOF
done
chmod +x "$FAKES"/* "$FAKES"/bin/*

make_app() {
  local path="$1" version="$2" team="$3"
  mkdir -p "$path/Contents"
  echo "$version" >"$path/Contents/version"
  echo "$team" >"$path/Contents/team"
}

CASE_DIR=""
INSTALLER_OUTPUT=""

# setup_case NAME [candidate team]: a fresh install dir holding version 1 and
# a disk image holding version 2.
setup_case() {
  CASE_DIR="$TMP/$1"
  mkdir -p "$CASE_DIR/Applications" "$CASE_DIR/state" "$CASE_DIR/dmg" "$CASE_DIR/tmp"
  make_app "$CASE_DIR/Applications/WhiskerFlow.app" 1 G9U38P58ZY
  make_app "$CASE_DIR/dmg/WhiskerFlow.app" 2 "${2:-G9U38P58ZY}"
  touch "$CASE_DIR/WhiskerFlow.dmg" "$CASE_DIR/log" "$CASE_DIR/state/mounts"
  echo 0 >"$CASE_DIR/state/running"
}

# The installer is fed on stdin, as `curl … | bash` does, so it cannot rely on
# its own path.
run_installer() {
  local status=0
  INSTALLER_OUTPUT="$(env \
    PATH="$FAKES/bin:$PATH" \
    TMPDIR="$CASE_DIR/tmp" \
    FAKE_LOG="$CASE_DIR/log" \
    FAKE_STATE="$CASE_DIR/state" \
    FAKE_DMG_APP="$CASE_DIR/dmg/WhiskerFlow.app" \
    WHISKERFLOW_INSTALL_DIR="$CASE_DIR/Applications" \
    WHISKERFLOW_DMG="$CASE_DIR/WhiskerFlow.dmg" \
    WHISKERFLOW_VERIFY_SCRIPT="$VERIFY_SCRIPT" \
    WHISKERFLOW_QUIT_TIMEOUT=2 \
    EXPECTED_TEAM_ID=G9U38P58ZY \
    CODESIGN_BIN="$FAKES/codesign" \
    HDIUTIL_BIN="$FAKES/hdiutil" \
    SPCTL_BIN="$FAKES/spctl" \
    OSASCRIPT_BIN="$FAKES/osascript" \
    OPEN_BIN="$FAKES/open" \
    "$@" bash <"$INSTALL_SCRIPT" 2>&1)" || status=$?
  return "$status"
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- installer output" >&2
  echo "$INSTALLER_OUTPUT" >&2
  echo "--- fake tool log" >&2
  cat "$CASE_DIR/log" >&2
  exit 1
}

installed_version() {
  cat "$CASE_DIR/Applications/WhiskerFlow.app/Contents/version"
}

assert_installed() {
  [[ "$(installed_version)" == "$1" ]] || fail "$2: expected version $1 installed, found $(installed_version)"
}

# Every run must detach what it mounted, delete its temp files and leave no
# staging copies beside the installed app.
assert_clean() {
  local attached detached leftovers
  attached="$(grep -c '^attached' "$CASE_DIR/state/mounts" || true)"
  detached="$(grep -c '^detached' "$CASE_DIR/state/mounts" || true)"
  [[ "$attached" == "$detached" ]] || fail "$1: disk image left attached"
  [[ -z "$(ls -A "$CASE_DIR/tmp")" ]] || fail "$1: temp files left behind"
  leftovers="$(find "$CASE_DIR/Applications" -mindepth 1 -maxdepth 1 ! -name WhiskerFlow.app)"
  [[ -z "$leftovers" ]] || fail "$1: staging files left in the install dir: $leftovers"
}

assert_never_called() {
  local pattern="$1" label="$2"
  if grep -Eq "$pattern" "$CASE_DIR/log"; then
    fail "$label"
  fi
}

assert_common() {
  assert_clean "$1"
  assert_never_called '^xattr' "$1: quarantine attribute must not be removed"
  assert_never_called '^(kill|pkill|killall|osascript force-terminate)' "$1: the app must never be force-killed"
  assert_never_called '^curl' "$1: local overrides must not touch the network"
}

# Happy path: not running, installed, Gatekeeper consulted, quarantine kept.
setup_case happy
run_installer || fail "happy path: installer failed"
assert_installed 2 "happy path"
grep -q '^spctl --assess --type execute ' "$CASE_DIR/log" || fail "happy path: Gatekeeper was not consulted"
assert_never_called '^osascript terminate' "happy path: quit requested though the app was not running"
assert_never_called '^open' "happy path: app opened though it was not running before"
assert_common "happy path"

# Fresh install with no existing app.
setup_case fresh
rm -rf "$CASE_DIR/Applications/WhiskerFlow.app"
run_installer || fail "fresh install: installer failed"
assert_installed 2 "fresh install"
assert_common "fresh install"

# Gatekeeper rejection leaves the existing app alone.
setup_case gatekeeper
if run_installer FAKE_SPCTL_REJECT=1; then
  fail "Gatekeeper rejection: installer succeeded"
fi
assert_installed 1 "Gatekeeper rejection"
[[ "$INSTALLER_OUTPUT" == *"Gatekeeper rejected"* ]] || fail "Gatekeeper rejection: no clear message"
assert_common "Gatekeeper rejection"

# Identity check failure leaves the existing app alone, before Gatekeeper.
setup_case identity OTHERTEAM1
if run_installer; then
  fail "identity failure: installer succeeded"
fi
assert_installed 1 "identity failure"
assert_never_called '^spctl' "identity failure: continued past the identity check"
assert_common "identity failure"

# A running app that will not quit: abort without touching the install.
setup_case stuck
echo 1 >"$CASE_DIR/state/running"
if run_installer FAKE_APP_QUITS=0; then
  fail "app does not quit: installer succeeded"
fi
assert_installed 1 "app does not quit"
grep -q '^osascript terminate' "$CASE_DIR/log" || fail "app does not quit: graceful quit was not requested"
[[ "$INSTALLER_OUTPUT" == *"run the installer again"* ]] || fail "app does not quit: no instruction to rerun"
assert_never_called '^open' "app does not quit: app was reopened"
assert_common "app does not quit"

# A running app that quits is replaced and reopened.
setup_case quits
echo 1 >"$CASE_DIR/state/running"
run_installer FAKE_APP_QUITS=1 || fail "app quits: installer failed"
assert_installed 2 "app quits"
grep -q '^osascript terminate' "$CASE_DIR/log" || fail "app quits: graceful quit was not requested"
grep -q "^open $CASE_DIR/Applications/WhiskerFlow.app" "$CASE_DIR/log" || fail "app quits: app was not reopened"
assert_common "app quits"

# A disk image without WhiskerFlow.app is rejected and still detached.
setup_case badimage
mkdir -p "$CASE_DIR/dmg/Other.app"
if run_installer FAKE_DMG_APP="$CASE_DIR/dmg/Other.app"; then
  fail "bad disk image: installer succeeded"
fi
assert_installed 1 "bad disk image"
assert_common "bad disk image"

echo "PASS: installer verifies, quits gracefully, replaces safely and cleans up"
