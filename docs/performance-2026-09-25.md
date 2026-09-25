# Dictation latency pass — 25 September 2026

Measured on Jacob's Apple M5 MacBook Pro (16 GB, heavy swap at the time). Field numbers come from `~/Library/Logs/WhiskerFlow/diagnostics.jsonl` (dev build `3c91b3d28f68-20260917T183728Z`). Lab numbers come from microbenchmarks and a real `AppState` driven programmatically under an isolated `CFFIXED_USER_HOME` and a separate bundle ID, with a no-op delivery service. That harness was temporary and has been removed.

## Findings

| Area | Before | After | Change |
|---|---:|---:|---|
| Hotkey → microphone live | 300–340 ms in the field; 134–220 ms in the lab | ~22 ms in the lab | An engine is kept prepared (device assigned, tap installed, `prepare()`d, not started), and the TCC query is skipped once the mic is granted |
| Key release → capture stopped | ~160–200 ms in the field; 23–41 ms in the lab | ~6 ms in the lab | Engine deallocation moved off the main actor |
| Release → text delivered, 11 s clip, optimized build, idle 3 s / 30 s / 75 s | 142–151 / 158 / 242–323 ms | 103–110 / 103 / 116–145 ms | Parakeet warm-up at key press, repeated every 4 s while held |
| Same 11 s clip decoded after 60 s idle (release config) | up to 4,157 ms; 365–420 ms is typical | 155 ms when warmed at press | Core ML / Neural Engine state decays within seconds to a minute |
| "Pasting…" HUD after the text lands | ~0.9–1.0 s | 0 ms | Status turns to "Pasted" when the keystroke is posted; verification and clipboard restore continue in the background |
| Accessibility round trips before ⌘V | ~10 | ~5 | The correction target reuses the paste snapshot |
| Debug vs release decode (3.9–74 s clips) | debug is 1.5–1.8× slower | — | `bundle_app.sh` now builds debug bundles with `-O` in `.build/optimized` (set `OPTIMIZE=0` to opt out) |

File-backed and in-memory Parakeet decodes take the same time (`DictationPerformanceTests`), but they differed in wording on 2 of 8 clips. The disk-backed path was therefore kept.

## Main-actor work removed

- **Paste correction monitor:** it polled the destination over Accessibility every 500 ms for 2 minutes after each paste; it now does this on a utility task.
- **HUD:** `signalQuality` was written per buffer, re-running `show()` and a panel layout ~10×/s; it is now written only when it changes. The waveform reads `audioLevel` in its own view, so the Dictate screen, menu popover and HUD no longer rebuild at buffer rate.
- **Keychain:** the Atlas token was read on every hotkey press and in view bodies; it is now cached in `AppSettings`.
- **Disk space:** the Meetings free-space query (CacheDelete XPC) was run in the view body; it is now refreshed off-main.
- **Meeting capture:** chunk encryption and writes run on a serial queue.
- **Meeting upload:** chunk reads, hashes and manifest rewrites run on detached tasks.
- **Live partials:** WhisperKit partials reuse one compiled vocabulary.
- **History store:** `TranscriptStore.add` no longer scans the Recordings directory (`load` still sweeps orphans), and `markTranscribing` skips a redundant write.
- **App Nap:** it is disabled while the hotkey is armed, and a latency-critical activity is held from key press to delivery.

## Not changed

- The clipboard backup before ⌘V can block on promised pasteboard data. It must be read before the clipboard is replaced.
- The launch-time meeting warm-up keeps WhisperKit medium and SpeakerKit loaded while Meeting Mode is on.
- `AssistantController.update` re-encodes its full state on the main actor.

## Reproduce

- Decode timings: `script/benchmark_dictation.sh <manifest.json> <results.json>`.
- Idle decay: `WHISKERFLOW_BENCHMARK_IDLE_AUDIO=<wav> swift test -c release --filter DictationPerformanceTests/testDecodeLatencyAfterIdleWithAndWithoutWarmUp`.

## Follow-up: speaker echo and live HUD text

- **Ignore audio from speakers** (Settings, on by default) turns on Apple voice processing for the dictation microphone.
  - It cancels what this Mac is playing out of the mic signal.
  - It enables the system Mic Mode picker (Settings → Microphone Mode…), where Voice Isolation suppresses other voices nearby.
  - Other audio is not ducked (`duckingLevel: .min`).
  - The processed voice is taken from channel 0 of the voice-processing unit's multichannel input (9 channels on this MacBook Pro).
  - A device that refuses voice processing records without it.
- **Cost of voice processing:** building the engine takes 0.6–1.2 s, which the prepared engine keeps off the hotkey path. Starting from the prepared engine took 46 ms.
- **Not verified:** how much echo is actually removed. The lab microphone delivered silence (no TCC grant for the test binary), so this still needs a manual check with a video playing through the speakers.
- **Live transcription** now works for Parakeet.
  - While recording, the last ≤12 s are decoded every ≥0.4 s of new audio for the HUD only (76 ms for 5 s, 96 ms for 11 s, text matching the full decode).
  - Previews never queue behind or interleave with the release-time decode.
  - The pasted text still comes from the full decode on release.
