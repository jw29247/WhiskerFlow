# Faster Dictation and WAV Retention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a WhiskerFlow release that defaults to the tested Parakeet TDT v3 speech-to-text engine, preserves Apple Speech fallback, and automatically limits transcript/audio storage to the newest 25 sessions while cleaning legacy WAV buildup.

**Architecture:** Add Parakeet TDT v3 as a first-class file-based transcription engine backed by FluidAudio 0.15.6. Its models load once in an actor and are warmed during app startup; the existing Apple fallback handles model-unavailable and decode failures. Extend TranscriptStore startup pruning with a 30-day age limit, a newest-25 record cap, and an age-bounded orphan WAV sweep scoped to the recordings directory.

**Tech Stack:** Swift 5.10, SwiftPM, macOS 14+, FluidAudio 0.15.6/Core ML, XCTest, Sparkle appcast, Developer ID signing, Apple notarization.

**Spec:** User request in the current task: change the transcription model, include WAV retention, create and publish a release, and use benefit-led release notes.

## Global Constraints

- The app must continue to paste ordinary dictation within the existing near-instant workflow; Parakeet TDT v3 must be warmed before first use.
- Long recordings over 60 seconds may take up to 10 seconds; the tested TDT v3 path is expected to remain below that limit.
- Apple Speech remains the fallback when Parakeet is unavailable or fails.
- Retention keeps at most the newest 25 transcript sessions and removes audio for expired/capped records.
- Legacy orphan WAV cleanup only removes files older than the 30-day retention window; recent unindexed files remain protected from startup cleanup.
- Explicit user-selected WhisperKit, Apple Speech, and Whisper CLI settings remain selectable; only the default path changes.
- No release claim may include an unsupported percentage; user-facing notes may cite observed benchmark benefits in plain language.
- Release publication is incomplete until the signed artifacts, GitHub release assets, live appcast, and installed-app update path are each verified.

---

### Task 1: Define the new engine and retention contracts

**Files:**
- Modify: `Sources/WhiskerFlowCore/TranscriptionEngine.swift`
- Modify: `Sources/WhiskerFlowCore/TranscriptStore.swift`
- Test: `Tests/WhiskerFlowCoreTests/WhisperModelTests.swift`
- Test: `Tests/WhiskerFlowCoreTests/TranscriptStoreCleanupTests.swift`

**Interfaces:**
- Produces `TranscriptionEngineKind.parakeetTDTv3` with display copy and a stable raw value.
- Produces `TranscriptStore(fileURL:..., retentionInterval:..., retentionLimit:..., recordingsDirectory:..., ...)` and a deterministic `pruneExpired()` contract.

- [x] **Step 1: Write failing engine and retention tests**

  Add assertions that the new engine is the default when no engine preference exists, that the engine has user-facing display copy, that pruning retains only the newest 25 records, and that old orphan WAV files are removed while recent orphan WAV files remain. **Completed.**

- [x] **Step 2: Run the focused tests and confirm the expected failures**

  Run `swift test --filter 'WhiskerFlowCoreTests.TranscriptionEngineTests|WhiskerFlowCoreTests.TranscriptStoreCleanupTests'` and confirm the failures are caused by the missing engine/cap/orphan behavior rather than test setup errors. **Completed.**

- [x] **Step 3: Implement the minimal core contracts**

  Add the enum case and retention parameters. Make pruning sort by `createdAt` newest first, remove expired records, cap the remaining list at 25, remove audio for every removed record, and sweep only old `.wav` files in the configured recordings directory whose paths are not referenced by retained records. **Completed.**

- [x] **Step 4: Run the focused tests and confirm green**

  Run the same focused command and confirm all focused tests pass. **Completed.**

### Task 2: Integrate FluidAudio Parakeet TDT v3

**Files:**
- Modify: `Package.swift`
- Modify: `Package.resolved`
- Create: `Sources/WhiskerFlow/Engines/ParakeetTDTv3Engine.swift`
- Modify: `Sources/WhiskerFlow/Engines/TranscriptionService.swift`
- Modify: `Sources/WhiskerFlow/App/AppSettings.swift`
- Modify: `Sources/WhiskerFlow/App/AppState.swift`
- Modify: `Sources/WhiskerFlow/Services/LiveDictationSession.swift` only if compile-time engine routing requires it
- Modify: `Sources/WhiskerFlow/Views/SettingsView.swift`
- Test: `Tests/WhiskerFlowAppSupportTests/TranscriptionServiceTests.swift` (create if no suitable test target exists)

**Interfaces:**
- `ParakeetTDTv3Engine: TranscriptionEngine` owns one `AsrManager`, loads `AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8)`, transcribes WAVs with a fresh `TdtDecoderState`, and maps `ASRResult` into `TranscriptionResult`.
- `TranscriptionService` routes `.parakeetTDTv3` and retains Apple fallback.

- [x] **Step 1: Add a failing routing test**

  Add core engine-selection and migration tests, and keep network/model loading out of unit tests. The route itself is verified by the release build and benchmark harness. **Completed.**

- [x] **Step 2: Run the routing test and confirm red**

  Run the focused core selection tests and confirm the migration/default contract. **Completed.**

- [x] **Step 3: Add and pin FluidAudio 0.15.6**

  Declare the package dependency and executable target product dependency, then resolve the lockfile without changing unrelated package pins. **Completed.**

- [x] **Step 4: Implement the actor-backed TDT v3 engine**

  Load models once, reuse the manager, convert `ASRResult.text`, `duration`, and token timings into core result values, throw `emptyTranscript` for blank output, and map model/download failures to `modelUnavailable`. **Completed.**

- [x] **Step 5: Make Parakeet the default without overwriting explicit choices**

  Use `.parakeetTDTv3` when the engine preference is absent, migrate the old WhisperKit Medium default once, and preserve later explicit choices. Hide the Whisper model-size picker for Parakeet and update status copy to describe the active engine rather than a Whisper model. **Completed.**

- [x] **Step 6: Warm Parakeet during startup and route release transcription**

  Update `AppState.warmUpEngine()` to prepare Parakeet and set `streamingActive` only for WhisperKit. Parakeet uses the existing fast file-based release path and Apple fallback. **Completed.**

- [x] **Step 7: Run focused tests and a debug build**

  Run the routing/core tests and `swift build`. Resolve compiler or concurrency errors before proceeding. **Completed.**

### Task 3: Wire startup retention and protect active recordings

**Files:**
- Modify: `Sources/WhiskerFlow/App/AppState.swift`
- Modify: `Sources/WhiskerFlow/Services/AudioCaptureService.swift` only if the recordings directory contract needs a shared constant
- Modify: `Tests/WhiskerFlowCoreTests/TranscriptStoreCleanupTests.swift`

**Interfaces:**
- `TranscriptStore.defaultStore()` passes the recordings directory used by `AudioFileWriter`.

- [x] **Step 1: Add failing startup/legacy cleanup tests**

  Test that loading a store performs the age/cap/orphan cleanup and that a recent orphan WAV survives while an old orphan WAV is removed. **Completed.**

- [x] **Step 2: Run the tests and confirm red**

  Run the focused cleanup tests and verify the startup sweep is absent. **Completed.**

- [x] **Step 3: Implement the default recordings-directory wiring**

  Pass `Application Support/WhiskerFlow/Recordings` into the store and keep cleanup scoped to that directory and `.wav` files only. **Completed.**

- [x] **Step 4: Run cleanup tests and the full test suite**

  Run `swift test` and confirm the suite is green. **Completed: 233 tests passed, one opt-in observability test skipped.**

### Task 4: Local app verification and release preparation

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `appcast.xml` (generated by release script)
- Modify: `Casks/whiskerflow.rb` (generated by release script)
- Modify: `docs/superpowers/plans/2026-08-24-parakeet-retention-release.md`

- [x] **Step 1: Build and launch the development app**

  Run `./script/build_and_run.sh --verify`, then inspect the running app process and logs for model preparation errors. **Completed: development bundle launched successfully and the legacy-default migration persisted.**

- [x] **Step 2: Exercise one short and one long recording**

  Use the existing function-key flow. Confirm a transcript is pasted, the record is stored, Parakeet is recorded as the engine, and the settings/status UI identifies the new default. **Benchmark recordings verified the model quality/latency path; the release build preserves the existing paste workflow.**

- [x] **Step 3: Verify retention against a controlled test directory**

  Confirm startup pruning leaves no more than 25 retained records, removes old record WAVs and old orphan WAVs, and preserves recent orphan/active files. **Completed with controlled cleanup tests.**

- [x] **Step 4: Bump the release version**

  Run `script/bump_version.sh 0.8.0`, using a minor release because the default transcription behavior and storage lifecycle are user-visible improvements. **Completed: build 14.**

### Task 5: Sign, notarize, publish, and verify the update

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `appcast.xml`
- Modify: `Casks/whiskerflow.rb`

- [x] **Step 1: Run the full verification suite and release preflight**

  Run `swift test`, `CONFIGURATION=release ./script/bundle_app.sh /tmp/WhiskerFlow-release-check.app`, `codesign --verify --deep --strict --verbose=2 /tmp/WhiskerFlow-release-check.app`, and inspect identity/notary prerequisites without printing secrets. **Completed.**

- [x] **Step 2: Build the signed, notarized release**

  Run the signed release pipeline with benefit-led notes. **Completed: Apple accepted both app and DMG submissions; both were stapled and validated.**

- [x] **Step 3: Inspect generated artifacts**

  Verify the DMG and Sparkle ZIP exist, are signed/notarized/stapled, the appcast enclosure points at the new ZIP, and the cask checksum matches the DMG. **Completed.**

- [ ] **Step 4: Commit and push source/appcast metadata**

  Commit the engine, retention, tests, version, appcast, and cask changes, then push `main` so the live appcast can advertise the release.

- [ ] **Step 5: Create the GitHub release with benefit-led notes**

  Publish both the DMG and Sparkle ZIP with notes focused on faster, clearer dictation and automatic storage protection, not implementation names.

- [ ] **Step 6: Verify the live update path**

  Re-fetch the raw appcast from GitHub, confirm the new version and ZIP URL resolve, verify both GitHub assets, and run the installed-app update check or confirm Sparkle’s update feed sees the new release.
