# WhiskerFlow

On-device push-to-talk dictation for macOS. Hold a key, speak, release — WhiskerFlow
transcribes locally and pastes the text wherever your cursor is.

- **Fast & private** — dictation uses Parakeet TDT v3 on-device by default. Optional
  Meeting Mode uploads meeting recordings and transcripts to the connected Atlas
  account. Operational telemetry excludes audio and transcript text.
- **Zero-setup install** — no Python, no Homebrew Whisper. The model downloads itself on first use.
- **Works offline too** — a built-in Apple Speech engine needs no download at all.
- **Floating HUD** with a live level meter, a rich menu-bar popover, searchable/editable
  history, custom-vocabulary replacement, configurable hotkey, and hold-to-talk or tap-to-toggle modes.

## Requirements

- macOS 14 (Sonoma) or later — Apple Silicon recommended for WhisperKit.

## Install

**One-line installer** (recommended — downloads and installs the latest notarized release):

```sh
curl -fsSL https://raw.githubusercontent.com/jw29247/WhiskerFlow/main/script/install.sh | bash
```

**Manual** — download `WhiskerFlow-x.y.z.dmg` from [Releases](https://github.com/jw29247/WhiskerFlow/releases/latest),
open it, and drag the app to Applications. Builds are Developer-ID signed and notarized,
so they open normally — no right-click → Open needed.

**Homebrew cask** — modern Homebrew no longer installs casks from a raw URL, so use the tap:

```sh
brew tap jw29247/whiskerflow https://github.com/jw29247/WhiskerFlow
brew install --cask jw29247/whiskerflow/whiskerflow   # Homebrew may first ask you to `brew trust` the tap
```

Once installed, **updates are automatic** — WhiskerFlow checks for and installs new
releases in place (Sparkle), so the install step above is one-time.

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
| Parakeet TDT v3 (default) | model on first use | after download | Fast on-device dictation, Apple Silicon |
| WhisperKit | depends on model size | after download | Optional live transcription, Neural Engine |
| Apple Speech | none | always | Built into macOS, instant |
| Whisper CLI (advanced) | your own `openai-whisper` | yes | Point at a local install |

Pick the engine, model size, and language in **Settings → Engine**.

## Build from source

```sh
swift build          # build
swift test           # run the Core and AppSupport test suites
swift run WhiskerFlow # run (or use script/build_and_run.sh to run as a .app bundle)
```

Verify that a span, structured log, and metric reach Superlog:

```sh
SUPERLOG_LIVE_SMOKE=1 swift test --filter ObservabilitySmokeTests
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
  analytics, search, vocabulary, transcription request/result models, and shared value types.
- **`WhiskerFlow`** (app target) — SwiftUI/AppKit UI plus the engines
  (`ParakeetTDTv3Engine`, `WhisperKitEngine`, `AppleSpeechEngine`, `WhisperCLIEngine`) behind a
  `TranscriptionService` coordinator, audio capture, paste, and hotkey services.

## Notes on signing

Local builds use ad-hoc signing. Public releases use `script/notarize.sh` with
Developer ID signing, Apple notarization, and a signed Sparkle update archive.
See [AGENT.md](AGENT.md) for the complete release and appcast publishing steps.
