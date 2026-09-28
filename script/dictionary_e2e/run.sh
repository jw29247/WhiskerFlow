#!/usr/bin/env bash
# End-to-end check that a correction made after a paste lands in the Dictionary.
#
#   script/dictionary_e2e/run.sh            # build, launch, run the Chrome chat-box rounds
#
# Speech is `say` through the speakers into the default mic, so the room hears it.
# The candidate is a DEBUG build signed with the Developer ID and the production
# bundle ID (TCC grants apply). It runs with its own home and preferences, and
# starts dictation from a distributed notification instead of fn, so the
# installed app is left alone. Needs an unlocked screen and a free Chrome window.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export WF_E2E_DIR="${WF_E2E_DIR:-/tmp/wf-dict-e2e}"
SIGN_IDENTITY="${SIGN_IDENTITY:?Set SIGN_IDENTITY to the Developer ID Application identity}"
SUITE=agency.thatworks.WhiskerFlow.e2e
HOME_DIR="$WF_E2E_DIR/home"
AS="$HOME/Library/Application Support"

mkdir -p "$WF_E2E_DIR"
for tool in axedit wfnotify axfocus axprobe; do
  swiftc -O "$ROOT/script/dictionary_e2e/$tool.swift" -o "$WF_E2E_DIR/$tool"
done
cp "$ROOT/script/dictionary_e2e/editor.html" "$WF_E2E_DIR/editor.html"

SIGN_IDENTITY="$SIGN_IDENTITY" BUNDLE_NAME_OVERRIDE="WhiskerFlow E2E" \
  "$ROOT/script/bundle_app.sh" "$WF_E2E_DIR/WhiskerFlow-E2E.app"

# Fresh data, shared models.
rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR/Library/Application Support/WhiskerFlow" "$HOME_DIR/Documents"
ln -s "$AS/WhiskerFlow/Models" "$HOME_DIR/Library/Application Support/WhiskerFlow/Models"
ln -s "$AS/FluidAudio" "$HOME_DIR/Library/Application Support/FluidAudio"
[[ -d "$HOME/Documents/huggingface" ]] && ln -s "$HOME/Documents/huggingface" "$HOME_DIR/Documents/huggingface"

# Own preferences: onboarding done, Parakeet, no speaker echo cancellation
# (it would cancel the `say` audio), no sounds, no meetings.
defaults delete "$SUITE" >/dev/null 2>&1 || true
defaults write "$SUITE" engine parakeetTDTv3
defaults write "$SUITE" language en
defaults write "$SUITE" languageAutoMigrated -bool true
defaults write "$SUITE" parakeetTDTv3DefaultMigrated -bool true
defaults write "$SUITE" recordingMode holdToTalk
defaults write "$SUITE" delivery pasteAtCursor
defaults write "$SUITE" ignoreSpeakerAudio -bool false
defaults write "$SUITE" liveTranscription -bool false
defaults write "$SUITE" meetingModeEnabled -bool false
defaults write "$SUITE" playSounds -bool false
defaults write "$SUITE" showMenuBarExtra -bool false
defaults write "$SUITE" onboardingProgress -data "$(python3 -c 'import json,time;print(json.dumps({"finishedAt":time.time()-978307200,"current":"done","furthest":"done","completed":[],"skipped":[]}).encode().hex())')"

pkill -f "$WF_E2E_DIR/WhiskerFlow-E2E.app" || true
open -n --env CFFIXED_USER_HOME="$HOME_DIR" "$WF_E2E_DIR/WhiskerFlow-E2E.app" \
  --args --debug-dictation-trigger --e2e-defaults-suite="$SUITE"
sleep 10
python3 "$ROOT/script/dictionary_e2e/rounds.py"
