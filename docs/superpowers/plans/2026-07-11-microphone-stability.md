# Microphone Stability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make microphone selection, startup, and hot-plug recovery deterministic so WhiskerFlow follows the macOS default input and never treats engine startup as a device disconnect.

**Architecture:** Keep stable CoreAudio UIDs and the explicit `system-default` sentinel already introduced on the stability branch. Add a small, deterministic observation gate in `WhiskerFlowAppSupport` so startup reconfiguration notifications cannot end a fresh recording, and add an ordered capture-candidate policy so a selected device that disappears during startup retries once with the current system default. The AppKit device picker continues to publish catalog and selection changes on deferred main-actor turns to avoid the crash seen in the device's SwiftUI/AppKit stack.

**Tech Stack:** Swift 5.10, SwiftPM, AVFoundation/AVAudioEngine, CoreAudio, XCTest, macOS 14+

## Global Constraints

- Preserve the existing uncommitted vocabulary fix.
- Persist stable CoreAudio UIDs only; never persist transient numeric `AudioDeviceID` values.
- Keep “System Default” as a real selectable route even when device enumeration is empty.
- Do not send microphone names, UIDs, transcript text, or file paths to diagnostics.
- Add a failing regression test before each production behavior change.

---

### Task 1: Ignore AVAudioEngine startup reconfiguration

**Files:**
- Create: `Sources/WhiskerFlowAppSupport/AudioConfigurationObservationGate.swift`
- Modify: `Sources/WhiskerFlow/Services/AudioCaptureService.swift`
- Test: `Tests/WhiskerFlowAppSupportTests/AudioConfigurationObservationGateTests.swift`

**Interfaces:**
- Produces: `AudioConfigurationObservationGate.captureStarted() -> UInt64`, `arm(_:) -> Bool`, `shouldHandleChange(for:) -> Bool`, and `captureStopped()`.
- Consumes: A generation token captured by `AudioCaptureService` when a recording starts.

- [ ] **Step 1: Write the failing gate tests**

```swift
func testStartupChangesAreIgnoredUntilCurrentGenerationIsArmed() {
    var gate = AudioConfigurationObservationGate()
    let generation = gate.captureStarted()
    XCTAssertFalse(gate.shouldHandleChange(for: generation))
    XCTAssertTrue(gate.arm(generation))
    XCTAssertTrue(gate.shouldHandleChange(for: generation))
}

func testStoppedCaptureRejectsDelayedArmAndStaleNotification() {
    var gate = AudioConfigurationObservationGate()
    let generation = gate.captureStarted()
    gate.captureStopped()
    XCTAssertFalse(gate.arm(generation))
    XCTAssertFalse(gate.shouldHandleChange(for: generation))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter AudioConfigurationObservationGateTests`

Expected: compilation fails because `AudioConfigurationObservationGate` does not exist.

- [ ] **Step 3: Implement the minimal generation gate**

```swift
public struct AudioConfigurationObservationGate: Sendable {
    private var generation: UInt64 = 0
    private var armedGeneration: UInt64?

    public init() {}

    public mutating func captureStarted() -> UInt64 {
        generation &+= 1
        armedGeneration = nil
        return generation
    }

    public mutating func arm(_ candidate: UInt64) -> Bool {
        guard candidate == generation else { return false }
        armedGeneration = candidate
        return true
    }

    public func shouldHandleChange(for candidate: UInt64) -> Bool {
        armedGeneration == candidate
    }

    public mutating func captureStopped() {
        generation &+= 1
        armedGeneration = nil
    }
}
```

- [ ] **Step 4: Arm observation only after the engine settles**

In `AudioCaptureService`, cancel any previous arm task during teardown. After `engine.start()` succeeds, create a generation token and wait 250 ms before arming and installing the `AVAudioEngineConfigurationChange` observer. The observer must capture that token and call `onConfigurationChange` only when `shouldHandleChange(for:)` remains true. A stopped or superseded capture invalidates the token.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run: `swift test --filter AudioConfigurationObservationGateTests`

Expected: 2 tests pass.

### Task 2: Retry a vanished selected microphone with system default

**Files:**
- Modify: `Sources/WhiskerFlowAppSupport/AudioDeviceModels.swift`
- Modify: `Sources/WhiskerFlow/App/AppState.swift`
- Test: `Tests/WhiskerFlowAppSupportTests/MicrophoneSelectionTests.swift`

**Interfaces:**
- Produces: `MicrophoneSelection.captureCandidates(for:) -> [AudioInputSelection]`.
- Consumes: The reconciled preferred selection immediately before `LiveDictationSession.start`.

- [ ] **Step 1: Write the failing candidate-order tests**

```swift
func testSpecificDeviceRetriesOnceWithSystemDefault() {
    XCTAssertEqual(
        MicrophoneSelection.captureCandidates(for: .device(uid: "usb-uid")),
        [.device(uid: "usb-uid"), .systemDefault]
    )
}

func testSystemDefaultIsAttemptedOnlyOnce() {
    XCTAssertEqual(
        MicrophoneSelection.captureCandidates(for: .systemDefault),
        [.systemDefault]
    )
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter MicrophoneSelectionTests`

Expected: compilation fails because `captureCandidates(for:)` does not exist.

- [ ] **Step 3: Implement the minimal fallback policy**

```swift
public static func captureCandidates(
    for preferred: AudioInputSelection
) -> [AudioInputSelection] {
    switch preferred {
    case .systemDefault:
        return [.systemDefault]
    case .device:
        return [preferred, .systemDefault]
    }
}
```

- [ ] **Step 4: Apply the policy during recording startup**

In `AppState.beginRecording`, attempt the candidates in order. If the selected device fails, fully reset the live capture and try `.systemDefault` once. Persist `.systemDefault` when fallback succeeds, record only the route kind in diagnostics, and rethrow the final error if every candidate fails.

- [ ] **Step 5: Run the focused tests and verify GREEN**

Run: `swift test --filter MicrophoneSelectionTests`

Expected: 5 tests pass.

### Task 3: Verify the complete stability path

**Files:**
- Review: `Sources/WhiskerFlow/App/AppState.swift`
- Review: `Sources/WhiskerFlow/Services/AudioCaptureService.swift`
- Review: `Sources/WhiskerFlow/Services/AudioDeviceChangeMonitor.swift`
- Review: `Sources/WhiskerFlow/Views/SettingsView.swift`
- Review: `Sources/WhiskerFlow/Services/DiagnosticsService.swift`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: A buildable app with regression-tested startup and fallback state transitions.

- [ ] **Step 1: Run all unit tests**

Run: `swift test`

Expected: all tests pass with zero failures.

- [ ] **Step 2: Build and verify the app bundle**

Run: `./script/build_and_run.sh --verify`

Expected: the SwiftPM GUI bundle builds, launches, and `pgrep -x WhiskerFlow` confirms the process.

- [ ] **Step 3: Inspect fresh audio logs**

Run: `/usr/bin/log show --last 5m --style compact --info --predicate 'process == "WhiskerFlow" AND (eventMessage CONTAINS[c] "Capture started" OR eventMessage CONTAINS[c] "configuration changed" OR messageType == error OR messageType == fault)'`

Expected: capture startup is not immediately followed by the app's “Active microphone configuration changed” handling; any remaining CoreAudio framework diagnostics are reported honestly.

- [ ] **Step 4: Check the final diff**

Run: `git diff --check && git status --short && git diff --stat`

Expected: no whitespace errors; only the preserved vocabulary fix, stability changes, tests, and this plan are modified.
