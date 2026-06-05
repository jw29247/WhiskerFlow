# WhiskerFlow

On-device push-to-talk dictation for macOS. Hold a key, speak, release — WhiskerFlow
transcribes locally and pastes the text wherever your cursor is.

- **Fast & private** — transcription runs on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Whisper on the Apple Neural Engine). Nothing is sent to a server.
- **Zero-setup install** — no Python, no Homebrew Whisper. The model downloads itself on first use.
- **Works offline too** — a built-in Apple Speech engine needs no download at all.
- **Floating HUD** with a live level meter, a rich menu-bar popover, searchable/editable
  history, custom-vocabulary replacement, configurable hotkey, and hold-to-talk or tap-to-toggle modes.

## Requirements

- macOS 14 (Sonoma) or later — Apple Silicon recommended for WhisperKit.

## Install

**Homebrew cask** (from this repo's tap/`Casks`):

```sh
brew install --cask ./Casks/whiskerflow.rb
```

**One-line installer** (downloads the latest release DMG):

```sh
curl -fsSL https://raw.githubusercontent.com/jw29247/WhiskerFlow/main/script/install.sh | bash
```

**Manual** — download `WhiskerFlow-x.y.z.dmg` from Releases, drag the app to Applications.
This build is ad-hoc signed (not notarized), so the first launch is right-click → Open.

After launching, the onboarding screen walks you through Microphone and Accessibility
permissions (Accessibility is what lets WhiskerFlow paste at the cursor).

## Usage

1. Hold **fn** (configurable) anywhere.
2. Speak. A floating HUD shows the live input level.
3. Release. The transcript is pasted at your cursor (or copied — your choice).

Open the main window for searchable history, inline editing, retry of failed runs,
and dictation stats. The menu-bar icon gives quick access to recent transcripts.

### Engines

| Engine | Download | Offline | Notes |
| --- | --- | --- | --- |
| WhisperKit (default) | ~150 MB model on first use | after download | Best accuracy, Neural Engine |
| Apple Speech | none | always | Built into macOS, instant |
| Whisper CLI (advanced) | your own `openai-whisper` | yes | Point at a local install |

Pick the engine, model size, and language in **Settings → Engine**.

## Build from source

```sh
swift build          # build
swift test           # run the WhiskerFlowCore test suite
swift run WhiskerFlow # run (or use script/build_and_run.sh to run as a .app bundle)
```

Package a distributable DMG + zip:

```sh
script/package_release.sh   # outputs dist/WhiskerFlow-<version>.dmg and .zip
```

Regenerate the app icon:

```sh
swift script/make_icon.swift Resources/AppIcon.iconset && \
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

## Architecture

- **`WhiskerFlowCore`** — pure, dependency-free, unit-tested: the transcript store,
  analytics, search, vocabulary, the `TranscriptionEngine` protocol, and shared value types.
- **`WhiskerFlow`** (app target) — SwiftUI/AppKit UI plus the engines
  (`WhisperKitEngine`, `AppleSpeechEngine`, `WhisperCLIEngine`) behind a
  `TranscriptionService` coordinator, audio capture, paste, and hotkey services.

## Notes on signing

The bundled build is ad-hoc signed for personal/friend distribution. Real
notarization needs an Apple Developer ID — wire your credentials into
`script/package_release.sh` (`codesign` + `xcrun notarytool`) when you have them.
