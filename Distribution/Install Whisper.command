#!/usr/bin/env zsh
set -euo pipefail

echo "WhiskerFlow Whisper installer"
echo

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install Whisper."
  echo "Install Homebrew from:"
  echo "https://brew.sh"
  echo
  echo "After installing Homebrew, run this file again."
  read -r "?Press Return to close."
  exit 1
fi

echo "Installing openai-whisper with Homebrew..."
brew install openai-whisper

WHISPER_PATH="$(command -v whisper || true)"
echo
echo "Whisper installed at: ${WHISPER_PATH:-not found on PATH}"
echo "WhiskerFlow will also look in /opt/homebrew/bin and /usr/local/bin."
echo
read -r "?Done. Press Return to close."
