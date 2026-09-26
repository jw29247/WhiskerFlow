import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

/// Silent tests: no microphone, audio playback or capture is started.
@MainActor
final class CallPromptAndCoachingTests: XCTestCase {
    private func coordinator(ask: Bool = true, detector: CallDetectionService? = nil) -> (MeetingCaptureCoordinator, AppSettings) {
        let name = "CallPromptTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        settings.askToRecordCalls = ask
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let coordinator = MeetingCaptureCoordinator(
            settings: settings,
            microphonePermission: MicrophonePermissionController(provider: AVCaptureMicrophoneAuthorizationProvider()),
            transcription: TranscriptionService(),
            store: EncryptedMeetingChunkStore(rootURL: root, keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))),
            clientProvider: { nil },
            callDetector: detector ?? CallDetectionService(readSignals: { CallDetectionSignals(inputs: [], windows: []) })
        )
        coordinator.canRecordDetectedCall = { true }
        return (coordinator, settings)
    }

    private let meet = DetectedCall(platform: .googleMeet, appBundleID: "com.google.Chrome", isBrowser: true, meetingCode: "abc-defg-hij")

    func testDetectedCallAsksOnceAndMatchesTheCalendar() {
        let (coordinator, settings) = coordinator()
        let now = MeetingCaptureCoordinator.nowMs()
        settings.cacheMeetingSchedule([AtlasCaptureScheduleIntent(
            eventID: "sync", title: "Weekly sync", startMs: now - 60_000, endMs: now + 1_800_000,
            meetingURL: "https://meet.google.com/abc-defg-hij", location: nil, existingMeetingID: nil, overlapsPrevious: false)])
        coordinator.handleCallEvent(.started(meet))
        XCTAssertEqual(coordinator.callPrompt?.intent?.eventID, "sync")
        XCTAssertEqual(coordinator.callPrompt?.title, "Weekly sync")
        coordinator.declineCallPrompt()
        XCTAssertNil(coordinator.callPrompt)
        coordinator.handleCallEvent(.started(meet))
        XCTAssertNil(coordinator.callPrompt, "Not now means not again for this call")
        coordinator.handleCallEvent(.ended(meet))
        coordinator.handleCallEvent(.started(meet))
        XCTAssertNotNil(coordinator.callPrompt, "A new call asks again")
        coordinator.handleCallEvent(.ended(meet))
        XCTAssertNil(coordinator.callPrompt, "The question disappears when the call ends")
    }

    func testCallsNotOnTheCalendarAreAskedAboutToo() {
        let (coordinator, _) = coordinator()
        let zoom = DetectedCall(platform: .zoom, appBundleID: "us.zoom.xos", isBrowser: false)
        coordinator.handleCallEvent(.started(zoom))
        XCTAssertNil(coordinator.callPrompt?.intent)
        XCTAssertEqual(coordinator.callPrompt?.title, "Zoom call")
    }

    func testNoQuestionWhenRecordingCouldNotStart() {
        let (coordinator, _) = coordinator()
        coordinator.canRecordDetectedCall = { false }
        coordinator.handleCallEvent(.started(meet))
        XCTAssertNil(coordinator.callPrompt, "Without microphone and Mac-audio access, Record would fail")
    }

    func testAskingCanBeTurnedOff() {
        let (coordinator, _) = coordinator(ask: false)
        coordinator.handleCallEvent(.started(meet))
        XCTAssertNil(coordinator.callPrompt)
    }

    func testDetectorTurnsNativeSignalsIntoEvents() async {
        final class Signals: @unchecked Sendable { var current = CallDetectionSignals(inputs: [], windows: []) }
        let signals = Signals()
        let detector = CallDetectionService(ownBundleID: "agency.thatworks.WhiskerFlow", readSignals: { signals.current })
        var events: [CallSessionTracker.Event] = []
        detector.onEvent = { events.append($0) }
        signals.current = CallDetectionSignals(inputs: [AudioInputProcess(pid: 1, bundleID: "com.microsoft.teams2")], windows: [])
        await detector.poll(now: 0)
        await detector.poll(now: 3)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(detector.activeCalls.map(\.platform), [.teams])
        signals.current = CallDetectionSignals(inputs: [], windows: [])
        await detector.poll(now: 10)
        await detector.poll(now: 30)
        XCTAssertEqual(events.last, .ended(DetectedCall(platform: .teams, appBundleID: "com.microsoft.teams2", isBrowser: false)))
        XCTAssertTrue(detector.activeCalls.isEmpty)
    }

    // MARK: Coaching

    private func coach(now: Date = Date(timeIntervalSince1970: 1_000)) throws -> MeetingAssistantController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Coach-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let controller = MeetingAssistantController(rootURL: root, now: { now })
        controller.isCoachEnabled = true
        return controller
    }

    private func feed(_ controller: MeetingAssistantController, from start: Int, count: Int, own: Bool, system: Bool) {
        for second in start..<(start + count) {
            controller.recordActivity(.init(elapsedSeconds: Double(second), durationSeconds: 1, ownMicActivity: own, systemActivity: system))
        }
    }

    func testMonologueReminderAfterNinetySecondsOfYourTurn() throws {
        let controller = try coach()
        controller.begin(sessionID: UUID(), title: "Call")
        feed(controller, from: 0, count: 40, own: false, system: true)
        feed(controller, from: 40, count: 44, own: true, system: false)
        XCTAssertNil(controller.livePrompt)
        feed(controller, from: 84, count: 2, own: true, system: false)
        XCTAssertTrue(controller.livePrompt?.contains("speaking") == true, "The existing one-minute reminder comes first")
        controller.dismissPrompt()
        feed(controller, from: 86, count: 60, own: true, system: false)
        XCTAssertTrue(controller.livePrompt?.contains("without a break") == true, controller.livePrompt ?? "nil")
        XCTAssertGreaterThanOrEqual(controller.currentTurnSeconds, 90)
        XCTAssertNotNil(controller.talkShare)
    }

    func testTalkShareReminderNeedsEnoughRecentSpeech() throws {
        let controller = try coach()
        controller.begin(sessionID: UUID(), title: "Call")
        feed(controller, from: 0, count: 250, own: false, system: false)
        for block in 0..<5 {
            feed(controller, from: 250 + block * 30, count: 20, own: true, system: false)
            feed(controller, from: 270 + block * 30, count: 8, own: false, system: true)
            feed(controller, from: 278 + block * 30, count: 2, own: false, system: false)
        }
        XCTAssertTrue(controller.livePrompt?.contains("of the talking") == true, controller.livePrompt ?? "nil")
        XCTAssertEqual(controller.recentTalkShare ?? 0, 100.0 / 140, accuracy: 0.01)
    }

    func testPaceFromOwnSpeechAndFastPaceReminder() throws {
        let controller = try coach()
        controller.begin(sessionID: UUID(), title: "Call")
        feed(controller, from: 0, count: 120, own: false, system: true)
        XCTAssertFalse(controller.shouldTranscribeOwnSpeech(from: 100, to: 120), "Mostly the other side of the call")
        feed(controller, from: 120, count: 20, own: true, system: false)
        XCTAssertTrue(controller.shouldTranscribeOwnSpeech(from: 120, to: 140))
        let fast = Array(repeating: "word", count: 70).joined(separator: " ")
        controller.recordOwnSpeech(fast, from: 120, to: 140)
        XCTAssertEqual(controller.wordsPerMinute ?? 0, 210, accuracy: 0.5)
        feed(controller, from: 140, count: 1, own: false, system: true)
        XCTAssertTrue(controller.livePrompt?.contains("speaking quickly") == true, controller.livePrompt ?? "nil")
        controller.isLiveAnalysisEnabled = false
        XCTAssertFalse(controller.shouldTranscribeOwnSpeech(from: 120, to: 140), "No transcription when turned off")
    }

    private struct StubSuggester: MeetingCoachSuggesting {
        let result: MeetingCoachJudgement?
        func judgement(for request: MeetingCoachSuggestionRequest) async -> MeetingCoachJudgement? { result }
    }

    func testAISuggestionIsLabelledRatedAndCountedInTheSummary() async throws {
        let controller = try coach()
        controller.suggester = StubSuggester(result: MeetingCoachJudgement(defensiveTone: true))
        controller.isAISuggestionsEnabled = true
        let sessionID = UUID()
        controller.begin(sessionID: sessionID, title: "Call")
        // Alternate turns so no rule-based reminder takes the slot.
        for block in 0..<20 {
            feed(controller, from: block * 10, count: 5, own: true, system: false)
            feed(controller, from: block * 10 + 5, count: 5, own: false, system: true)
        }
        controller.recordOwnSpeech(Array(repeating: "fine", count: 80).joined(separator: " "), from: 180, to: 200)
        for _ in 0..<50 where controller.livePrompt == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
            feed(controller, from: 200, count: 1, own: false, system: true)
        }
        XCTAssertEqual(controller.livePrompt, MeetingCoachAdvice.acknowledgeConcerns.message(goal: ""))
        XCTAssertTrue(controller.livePromptIsAI)
        controller.rateSuggestion(helpful: true)
        controller.rateSuggestion(helpful: false)
        XCTAssertTrue(controller.didRateSuggestion)
        controller.end(sessionID: sessionID)
        let summary = try XCTUnwrap(controller.coachSummary(for: sessionID))
        XCTAssertEqual(summary.aiSuggestionsShown, 1)
        XCTAssertEqual(summary.aiHelpfulCount, 1)
        XCTAssertEqual(summary.aiNotHelpfulCount, 0, "One rating per suggestion")
        XCTAssertEqual(summary.youSeconds, 100)
        XCTAssertFalse(controller.wantsOwnSpeech, "Nothing is transcribed after the meeting ends")
    }

    func testNoSummaryWhenCoachingWasOff() throws {
        let controller = try coach()
        controller.isCoachEnabled = false
        let sessionID = UUID()
        controller.begin(sessionID: sessionID, title: "Call")
        feed(controller, from: 0, count: 60, own: true, system: false)
        controller.end(sessionID: sessionID)
        XCTAssertNil(controller.coachSummary(for: sessionID))
    }

    func testTranscriptPaceAndTrendsFromTheLibrary() {
        let turns = [
            MeetingSpeakerTurn(startMs: 0, endMs: 30_000, text: Array(repeating: "w", count: 70).joined(separator: " "), speaker: .microphone),
            MeetingSpeakerTurn(startMs: 30_000, endMs: 60_000, text: "others talk here", speaker: .diarized(key: "a", index: 1)),
        ]
        XCTAssertEqual(MeetingCoachTranscriptPace.wordsPerMinute(turns) ?? 0, 140, accuracy: 0.01)
        let library = MeetingLibraryController.ephemeral()
        let id = UUID()
        library.beginRecording(sessionID: id, title: "T", startedAt: Date(), calendarEventID: nil)
        library.finishRecording(id, endedAtMs: 60_000, coachRecap: nil, bookmarks: [], coachSummary: MeetingCoachSummary(
            durationSeconds: 60, youSeconds: 40, othersSeconds: 20, overlapSeconds: 0, longestMonologueSeconds: 30,
            monologueCount: 0, averageWordsPerMinute: 200, promptsShown: 0))
        library.recordTranscript(id, turns: turns, untranscribedAudibleWindowCount: 0)
        XCTAssertEqual(library.entry(id)?.coachSummary?.averageWordsPerMinute ?? 0, 140, accuracy: 0.01,
                       "The final transcript replaces the live pace estimate")
        XCTAssertEqual(library.coachTrends.meetingCount, 1)
        XCTAssertEqual(library.coachTrends.averageTalkShare ?? 0, 2.0 / 3, accuracy: 0.001)
    }
}

/// Opt-in, read-only probe of the real signals on this Mac. Prints counts and
/// platforms only, never titles. `WHISKERFLOW_CALL_PROBE=1 swift test --filter CallSignalProbeTests`
final class CallSignalProbeTests: XCTestCase {
    func testReadNativeSignals() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WHISKERFLOW_CALL_PROBE"] == "1", "Set WHISKERFLOW_CALL_PROBE=1")
        let start = Date()
        let signals = NativeCallSignalReader.read()
        let calls = CallDetectionRules.detect(inputs: signals.inputs, windows: signals.windows, ownBundleID: nil)
        var repeats: [Int] = []
        for _ in 0..<10 {
            let t = Date(); _ = NativeCallSignalReader.read(); repeats.append(Int(Date().timeIntervalSince(t) * 1_000_000))
        }
        print("CALL_PROBE_REPEAT_US: \(repeats)")
        print("CALL_PROBE: inputs=\(signals.inputs.count) browser_windows=\(signals.windows.count) titles=\(signals.windows.reduce(0) { $0 + $1.titles.count }) calls=\(calls.map(\.platform.rawValue)) ms=\(Int(Date().timeIntervalSince(start) * 1000))")
    }
}

@MainActor
final class CoachSettingsDefaultsTests: XCTestCase {
    func testAITipsAndPaceAreOnAndCallQuestionsAskedByDefault() {
        let name = "CoachSettingsDefaults.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        XCTAssertTrue(settings.coachAISuggestions)
        XCTAssertTrue(settings.coachLiveAnalysis)
        XCTAssertTrue(settings.askToRecordCalls)
        settings.coachAISuggestions = false
        XCTAssertFalse(AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name)).coachAISuggestions,
                       "Turning tips off is remembered")
    }
}
