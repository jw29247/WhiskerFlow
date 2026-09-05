# WhiskerFlow 2 UI Implementation Plan

Goal: Implement the approved three-destination macOS concept, preserving existing behavior and local changes.
Architecture: A fixed-width navigation rail composes focused SwiftUI workspaces. Shared adaptive tokens and controls unify every surface. A tested value-type editor state protects user drafts while the existing AppState and services remain authoritative.
Tech stack: SwiftUI / AppKit, SwiftPM, macOS 14+.
Spec: docs/design/2026-09-04-whiskerflow-2-overhaul.md. Approved by Jacob: “love the mock up, build it”.

## Constraints

- Preserve existing uncommitted meeting implementation.
- Preserve hotkeys, focus-safe paste, vocabulary, retry/export and all preferences.
- No published release or changes to installed production application/data.
- Use real state in the running application. Preview fixture data must be isolated and explicitly enabled.
- Respect light/dark appearance, keyboard focus, reduced motion and minimum window sizes.

## Work

- [x] Add TranscriptDraft in WhiskerFlowCore with tests for dirty selection protection, clean record completion, empty edits, save/discard, and changed source while dirty.
- [x] Add FlowStyle shared tokens, waveform, shortcut, status and action components.
- [x] Replace ContentView with navigation composition, guarded navigation and setup presentation. Add DictationView, HistoryView and MeetingsView.
- [x] Replace TranscriptDetailView with editor, copy feedback, delete confirmation, metadata disclosure and vocabulary suggestions.
- [x] Replace OnboardingView with focused microphone/accessibility steps; put meeting connection and system audio setup in reusable MeetingSetupView.
- [x] Reorganize SettingsView into Dictation, Text, Meetings, App and Advanced, retaining every preference callback.
- [x] Unify MenuBarView, RecordingHUDView and StatsView with the design system.
- [x] Build and test, then launch isolated UI preview for all screens, appearance modes, minimum sizing, editor navigation, empty/search states and settings.
- [x] Review final diff, record verification limits and show the completed local build.

## Verification

Run `swift test` (core and app support). Run `swift build` and the existing bundle script with a distinct bundle name and identifier. UI fixture mode must disable startup services, telemetry and automatic updates and use an isolated store. Never write fixtures into the real transcript directory or use real Atlas credentials for UI verification. Check actual rendered views via CUA and preserve screenshots in docs/design. Live dictation and Atlas recording remain separately identified if permissions or test input are unavailable.

Completion evidence and limitations: docs/design/2026-09-04-whiskerflow-2-validation.md. UI preview checks do not prove live audio or Atlas capture.
