# Meeting Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a clear Atlas Meeting Hub for upcoming and previous meetings plus scheduled and ad hoc recording actions.

**Architecture:** Extend the existing schedule poll and cached `AtlasCaptureScheduleIntent` model to cover seven days on either side of now. Expose bounded schedule sections and manual capture actions from the existing `MeetingCaptureCoordinator`, then render them in the existing onboarding/settings Meeting Mode surfaces without changing capture or upload internals.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, existing Atlas RPC client and encrypted meeting capture coordinator.

## Global Constraints

- Upcoming and previous windows are exactly seven days from the current time.
- Atlas remains the fixed production host `https://atlas.thatworks.agency`.
- Scheduled capture preserves `eventID`; ad hoc capture uses the existing nil-intent path.
- Do not change encryption, audio capture, upload, or transcription behavior.
- Do not change Atlas backend code or bypass Atlas CI.

---

### Task 1: Expand schedule data and coordinator actions

**Files:**
- Modify: `Sources/WhiskerFlow/Services/MeetingCaptureCoordinator.swift`
- Modify: `Sources/WhiskerFlow/App/AppState.swift`
- Test: `Tests/WhiskerFlowAppSupportTests/MeetingScheduleTests.swift`

**Interfaces:**
- Produce `upcomingMeetingIntents`, `previousMeetingIntents`, `refreshSchedule()`, and `startScheduledCapture(intent:)` on the coordinator/app-state surface used by SwiftUI.
- Preserve `toggleManualCapture()` for ad hoc start/stop.

- [ ] **Step 1: Add schedule classification tests** for seven-day future/past filtering and ordering.
- [ ] **Step 2: Run the focused schedule tests and confirm they fail before the new surface exists.**
- [ ] **Step 3: Extend the schedule poll range to `now - 7 days` through `now + 7 days`, retain cached fallback, and expose sorted bounded sections.**
- [ ] **Step 4: Add explicit refresh and scheduled-intent start methods that call the existing capture path.**
- [ ] **Step 5: Run the schedule tests and the full `swift test` suite.**

### Task 2: Build the Meeting Hub UI

**Files:**
- Modify: `Sources/WhiskerFlow/Views/SettingsView.swift`
- Modify: `Sources/WhiskerFlow/Views/OnboardingView.swift`
- Modify: `Sources/WhiskerFlow/Views/MenuBarView.swift`

**Interfaces:**
- Consume the coordinator/app-state schedule sections and actions from Task 1.

- [ ] **Step 1: Replace the “Uncovered” presentation with plain-language idle copy and Atlas connection context.**
- [ ] **Step 2: Add upcoming meeting rows with local date/time, event title, and Record/Recording state.**
- [ ] **Step 3: Add previous meeting rows with local date/time and capture state.**
- [ ] **Step 4: Add prominent “Start ad hoc recording” and explicit Refresh controls.**
- [ ] **Step 5: Keep compact menu-bar behavior readable while exposing the full hub through settings/onboarding.**
- [ ] **Step 6: Build and inspect the changed SwiftUI surfaces for layout and truncation issues.**

### Task 3: Verify, release, and publish

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `appcast.xml`
- Modify: `Casks/whiskerflow.rb`

- [ ] **Step 1: Run `git diff --check` and `swift test`.**
- [ ] **Step 2: Bump the app version with `script/bump_version.sh 0.8.3`.**
- [ ] **Step 3: Run signed `script/notarize.sh` with the existing notarization profile and confirm Apple accepts/staples both artifacts.**
- [ ] **Step 4: Publish both the DMG and Sparkle ZIP as GitHub release `v0.8.3`.**
- [ ] **Step 5: Commit and push release metadata and source changes, open a ready PR, and merge it with a merge commit.**
- [ ] **Step 6: Verify the release assets and appcast entry on `main`.**
