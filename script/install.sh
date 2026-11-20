#!/usr/bin/env bash
set -euo pipefail

# One-line installer:
#   curl -fsSL https://raw.githubusercontent.com/jw29247/WhiskerFlow/main/script/install.sh | bash
#
# Override the source repo with WHISKERFLOW_REPO=owner/name.
#
# The remaining overrides exist so script/test_install.sh can run the installer
# against temporary directories and fake system tools. Their defaults are the
# real tools and locations:
#   WHISKERFLOW_INSTALL_DIR        install location (default /Applications)
#   WHISKERFLOW_DMG                local disk image to install instead of downloading
#   WHISKERFLOW_VERIFY_SCRIPT      local identity check instead of fetching it
#   WHISKERFLOW_QUIT_TIMEOUT       seconds to wait for a running app to quit
#   HDIUTIL_BIN, SPCTL_BIN, OSASCRIPT_BIN, OPEN_BIN, CODESIGN_BIN
#
# Everything runs inside main(), called on the last line, so bash has read the
# whole script before acting even when it arrives through a pipe.

REPO="${WHISKERFLOW_REPO:-jw29247/WhiskerFlow}"
APP="WhiskerFlow"
BUNDLE_ID="agency.thatworks.WhiskerFlow"
INSTALL_DIR="${WHISKERFLOW_INSTALL_DIR:-/Applications}"
QUIT_TIMEOUT="${WHISKERFLOW_QUIT_TIMEOUT:-30}"
HDIUTIL_BIN="${HDIUTIL_BIN:-hdiutil}"
SPCTL_BIN="${SPCTL_BIN:-spctl}"
OSASCRIPT_BIN="${OSASCRIPT_BIN:-osascript}"
OPEN_BIN="${OPEN_BIN:-open}"

TMP=""
DMG="${WHISKERFLOW_DMG:-}"
MOUNT=""
STAGED=""

cleanup() {
  # Detach before deleting $TMP: the image is mounted inside it, and rm -rf
  # must never walk into a mounted volume.
  if [[ -n "$MOUNT" ]]; then
    if ! "$HDIUTIL_BIN" detach "$MOUNT" -quiet </dev/null >/dev/null 2>&1 \
      && ! "$HDIUTIL_BIN" detach "$MOUNT" -force -quiet </dev/null >/dev/null 2>&1; then
      echo "Warning: could not detach $MOUNT; leaving $TMP in place." >&2
      TMP=""
    fi
  fi
  if [[ -n "$STAGED" ]]; then
    rm -rf "$STAGED"
  fi
  if [[ -n "$TMP" ]]; then
    rm -rf "$TMP"
  fi
}

# Uses NSRunningApplication rather than AppleScript's `application id … is
# running`, which errors when WhiskerFlow has never been installed.
app_is_running() {
  local count
  count="$("$OSASCRIPT_BIN" -l JavaScript -e \
    "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$BUNDLE_ID').count" \
    </dev/null)"
  [[ "$count" != "0" ]]
}

# terminate is the same request as choosing Quit, so WhiskerFlow can finish
# saving a recording or ask for confirmation first. Never force-kill it: a
# forced quit can lose the recording in progress.
request_quit() {
  "$OSASCRIPT_BIN" -l JavaScript -e \
    "ObjC.import('AppKit'); var apps = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$BUNDLE_ID'); for (var i = 0; i < apps.count; i++) { apps.objectAtIndex(i).terminate; }" \
    </dev/null >/dev/null
}

quit_running_app() {
  echo "$APP is running; asking it to quit..."
  request_quit || true

  local waited=0
  while app_is_running; do
    if (( waited >= QUIT_TIMEOUT )); then
      echo "$APP is still running, so nothing was installed." >&2
      echo "Quit $APP (it may be saving a recording or waiting for you), then run the installer again." >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

download_dmg() {
  local dmg_url
  echo "Looking up the latest ${APP} release in ${REPO}..."
  dmg_url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -oE '"browser_download_url": *"[^"]+\.dmg"' \
    | head -1 \
    | sed -E 's/.*"(https[^"]+)"/\1/')

  if [[ -z "${dmg_url:-}" ]]; then
    echo "Could not find a .dmg in the latest release of $REPO." >&2
    echo "Build from source instead: swift run, or script/package_release.sh." >&2
    exit 1
  fi

  echo "Downloading $dmg_url"
  curl -fSL "$dmg_url" -o "$TMP/$APP.dmg"
  DMG="$TMP/$APP.dmg"
}

main() {
  trap cleanup EXIT
  # Turn interrupts into a normal exit so the EXIT trap still cleans up.
  trap 'exit 130' INT
  trap 'exit 143' TERM

  TMP="$(mktemp -d)"

  if [[ -z "$DMG" ]]; then
    download_dmg
  fi

  # A fixed mount point inside $TMP means cleanup always knows what to detach,
  # instead of parsing it from hdiutil's output.
  mkdir "$TMP/mount"
  MOUNT="$TMP/mount"
  if ! "$HDIUTIL_BIN" attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" </dev/null >/dev/null \
    || [[ ! -d "$MOUNT/$APP.app" ]]; then
    echo "Failed to mount the disk image." >&2
    exit 1
  fi

  local candidate="$MOUNT/$APP.app"
  local installed="$INSTALL_DIR/$APP.app"

  local verify_script="${WHISKERFLOW_VERIFY_SCRIPT:-}"
  if [[ -z "$verify_script" ]]; then
    verify_script="$TMP/verify_upgrade_identity.sh"
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/script/verify_upgrade_identity.sh" \
      -o "$verify_script"
  fi
  bash "$verify_script" "$candidate" "$installed" </dev/null

  # The quarantine flag is left in place: release builds are notarised, so
  # Gatekeeper accepts them on first launch. Assess now as well, so a build
  # Gatekeeper would reject never replaces a working install.
  if ! "$SPCTL_BIN" --assess --type execute "$candidate" </dev/null; then
    echo "Refusing to install: Gatekeeper rejected $APP.app from the disk image." >&2
    exit 1
  fi

  # Copy beside the destination first. Same volume, so the swap below is a
  # rename and the installed app is replaced only once the copy is complete.
  STAGED="$INSTALL_DIR/.$APP.app.installing-$$"
  rm -rf "$STAGED"
  cp -R "$candidate" "$STAGED"

  local was_running=0
  if app_is_running; then
    was_running=1
    quit_running_app
  fi

  echo "Installing to $INSTALL_DIR..."
  if [[ -e "$installed" ]]; then
    local previous="$INSTALL_DIR/.$APP.app.previous-$$"
    rm -rf "$previous"
    mv "$installed" "$previous"
    if ! mv "$STAGED" "$installed"; then
      mv "$previous" "$installed"
      echo "Failed to install $APP; the previous version was restored." >&2
      exit 1
    fi
    rm -rf "$previous"
  else
    mv "$STAGED" "$installed"
  fi
  STAGED=""

  if (( was_running )); then
    echo "Reopening $APP..."
    "$OPEN_BIN" "$installed" </dev/null || true
    echo "Installed."
  else
    echo "Installed. Open $APP from Applications, then grant Microphone + Accessibility."
  fi
}

main "$@"
