# WhiskerFlow

On-device push-to-talk dictation for macOS. Hold a key, speak, release — WhiskerFlow
transcribes locally and pastes the text wherever your cursor is.

- **Fast & private** — dictation uses Parakeet TDT v3 on-device by default. Optional
  Meeting Mode uploads meeting recordings and transcripts to the connected Atlas
  account. Operational telemetry excludes audio and transcript text.
- **Zero-setup install** — no Python, no Homebrew. The model downloads itself on first use.
- **Works offline too** — a built-in Apple Speech engine needs no download at all.
- **Styles by app category** — dictation into Messages, Slack, Mail, code editors, AI chats and documents
  is written in that category's tone (Formal, Casual, Very casual or Literal). Browsers are sorted by the
  website you're on. Change tones, or move individual apps, in **Assistant → Styles**; all rules run on this Mac.
- **Floating HUD** with a live level meter, a rich menu-bar popover, searchable/editable
  history, a Dictionary that learns names and fixes from your corrections (and can hint them to the recogniser), configurable hotkey, and hold-to-talk or tap-to-toggle modes.

## Requirements

- macOS 14 (Sonoma) or later on an Apple Silicon Mac. The release is arm64-only:
  FluidAudio, which runs the default Parakeet engine, does not build for Intel yet.

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
and Insights (lifetime words, speaking speed, streaks and activity). Choose how long
history is kept — forever, a year, 90 days (the default), 30 days, 7 days, 24 hours,
or not at all — in **Settings → History** or from the History screen. Insights keep
counts only, never transcript text, and survive any retention setting. The menu-bar
icon gives quick access to recent transcripts.

### Engines

| Engine | Download | Offline | Notes |
| --- | --- | --- | --- |
| Parakeet TDT v3 (default) | model on first use | after download | Fast on-device dictation and meeting transcripts, Apple Silicon |
| Apple Speech | none | always | Built into macOS; the fallback, and the only engine on Intel Macs |

Pick the engine and language in **Settings → Engine**. Whisper (WhisperKit and the
Whisper CLI) was removed; a build that finds its downloaded models deletes them.

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

- **`WhiskerFlowCore`** — pure, dependency-free (system SQLite only), unit-tested: the
  transcript store (`transcripts.sqlite`, migrated from the older `transcripts.json`,
  which is kept as a backup), retention, Insights aggregates, search, vocabulary, transcription request/result models, and shared value types.
- **`WhiskerFlow`** (app target) — SwiftUI/AppKit UI plus the engines
  (`ParakeetTDTv3Engine`, `AppleSpeechEngine`) behind a
  `TranscriptionService` coordinator, audio capture, paste, and hotkey services.

## Source compatibility in 0.8.6

This is a breaking source release for packages importing `WhiskerFlowCore` or
`WhiskerFlowAppSupport`. The macOS app's saved data and settings remain compatible.

Removed APIs: `TranscriptionEngine`, `TranscriptionRequest.initialPrompt` (including
its initializer argument), `AudioCapturing`, `SampleTranscribing`,
`AudioDeviceCataloging`, `AudioTapFormatPolicy`, `MicrophoneSelection.reconcile`,
`MicrophonePermissionController.refreshForApplicationActivation`,
`AgencyVocabularyPolicy.initialVocabulary`, `MeetingCoverageStatus`, and
`MeetingRecordingSessionManifest.isCompleteLocally`.

Source integrations should call their engine implementations directly, omit the
unused prompt, retain the selected microphone UID, and use `refresh()` for
permission refresh. Audio taps use the input node's hardware input format.

## Notes on signing

Local builds use ad-hoc signing. Public releases use `script/notarize.sh` with
Developer ID signing, Apple notarization, and a signed Sparkle update archive.
See [AGENT.md](AGENT.md) for the complete release and appcast publishing steps.
