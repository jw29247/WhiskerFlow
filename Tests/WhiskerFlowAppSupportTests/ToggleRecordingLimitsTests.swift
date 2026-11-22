import Foundation
import Logging
import XCTest
import WhiskerFlowCore
@testable import WhiskerFlowAppSupport

final class ToggleRecordingLimitsTests: XCTestCase {
    private let start: TimeInterval = 1_000

    func testLimitsAreAMinuteOfSilenceAndThirtyMinutes() {
        XCTAssertEqual(ToggleRecordingLimits.silenceSeconds, 60)
        XCTAssertEqual(ToggleRecordingLimits.maximumSeconds, 30 * 60)
        XCTAssertEqual(ToggleRecordingLimits.speechLevel, AudioSignalAssessor.quietLevelThreshold)
    }

    func testSilenceStopFiresAtTheLimitAndNotBefore() {
        var limits = ToggleRecordingLimits(startedAt: start)
        limits.noteSpeech(at: start + 5)
        XCTAssertNil(limits.autoStop(at: start + 5 + 59))
        XCTAssertNil(limits.autoStop(at: start + 5 + 59.9))
        XCTAssertEqual(limits.autoStop(at: start + 5 + 60), .silence)
    }

    func testNothingSaidStopsAMinuteAfterTheStart() {
        let limits = ToggleRecordingLimits(startedAt: start)
        XCTAssertNil(limits.autoStop(at: start + 59))
        XCTAssertEqual(limits.autoStop(at: start + 60), .noSpeech)
    }

    func testSpeechResetsTheSilenceCountdown() {
        var limits = ToggleRecordingLimits(startedAt: start)
        limits.noteSpeech(at: start + 50)
        XCTAssertNil(limits.autoStop(at: start + 100))
        limits.noteSpeech(at: start + 100)
        XCTAssertNil(limits.autoStop(at: start + 159))
        XCTAssertEqual(limits.autoStop(at: start + 160), .silence)
    }

    /// An earlier reading arriving late must not move the last speech back.
    func testOlderSpeechDoesNotRewindTheLastSpeech() {
        var limits = ToggleRecordingLimits(startedAt: start)
        limits.noteSpeech(at: start + 100)
        limits.noteSpeech(at: start + 40)
        XCTAssertEqual(limits.lastSpeechAt, start + 100)
    }

    func testLongDictationWithPausesRunsToTheMaximumLength() {
        var limits = ToggleRecordingLimits(startedAt: start)
        var time = start
        while time + 45 < start + ToggleRecordingLimits.maximumSeconds {
            limits.noteSpeech(at: time)
            time += 45
            XCTAssertNil(limits.autoStop(at: time), "Pauses under a minute never stop it")
        }
        limits.noteSpeech(at: start + ToggleRecordingLimits.maximumSeconds - 0.5)
        XCTAssertNil(limits.autoStop(at: start + ToggleRecordingLimits.maximumSeconds - 0.1))
        XCTAssertEqual(limits.autoStop(at: start + ToggleRecordingLimits.maximumSeconds), .maximumLength)
    }

    func testOnlyToggleDictationHasLimits() {
        XCTAssertTrue(ToggleRecordingLimits.apply(to: .toggle, assistantShortcut: false))
        XCTAssertFalse(ToggleRecordingLimits.apply(to: .holdToTalk, assistantShortcut: false))
        XCTAssertFalse(ToggleRecordingLimits.apply(to: .toggle, assistantShortcut: true),
                       "Assistant shortcuts end on release even in toggle mode")
        XCTAssertFalse(ToggleRecordingLimits.apply(to: .holdToTalk, assistantShortcut: true))
    }

    func testMessages() {
        XCTAssertEqual(ToggleAutoStop.silence.savedMessage(copiedToClipboard: false),
                       "Stopped after a minute of silence. Your text is in History.")
        XCTAssertEqual(ToggleAutoStop.silence.savedMessage(copiedToClipboard: true),
                       "Stopped after a minute of silence. Your text is in History and on the clipboard.")
        XCTAssertEqual(ToggleAutoStop.silence.savedMessage(inHistory: false, copiedToClipboard: true),
                       "Stopped after a minute of silence. Your text is on the clipboard.")
        XCTAssertEqual(ToggleAutoStop.maximumLength.savedMessage(copiedToClipboard: false),
                       "Stopped after 30 minutes. Your text is in History.")
        XCTAssertEqual(ToggleAutoStop.noSpeech.nothingSaidMessage,
                       "Stopped after a minute of silence. Nothing was said.")
    }

    func testAutoStopIsADistinctNormalStopReason() {
        let reason = CaptureStopReason.autoStopped(.silence)
        XCTAssertNotEqual(reason, .userReleased)
        XCTAssertTrue(reason.endsNormally, "The capture engine stays reusable for the next recording")
        XCTAssertFalse(CaptureStopReason.deviceDisconnected.endsNormally)
        XCTAssertEqual(CaptureStopReason.userReleased.diagnosticName, "userReleased")
        XCTAssertEqual(reason.diagnosticName, "autoStopped.silence")
        XCTAssertEqual(CaptureStopReason.autoStopped(.maximumLength).diagnosticName, "autoStopped.maximum_length")
        XCTAssertEqual(DiagnosticPrivacy.safeMetadata(from: ["stop_reason": reason.diagnosticName]),
                       ["stop_reason": "autoStopped.silence"])
    }

    func testCoordinatorKeepsTheAutoStopReason() async {
        await MainActor.run {
            let coordinator = RecordingCoordinator()
            let session = coordinator.requestStart()!
            XCTAssertTrue(coordinator.didStart(session))
            XCTAssertTrue(coordinator.requestFinish(session, reason: .autoStopped(.noSpeech)))
            XCTAssertEqual(coordinator.stopReason, .autoStopped(.noSpeech))
            // A press landing at the same moment finds the session already finishing.
            XCTAssertFalse(coordinator.requestFinish(session, reason: .userReleased))
            XCTAssertEqual(coordinator.stopReason, .autoStopped(.noSpeech))
        }
    }

    func testAutoStopIsKeptInTheLocalDiagnosticLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = LocalDiagnosticLog(directory: root)
        let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle",
                                    factory: { LocalDiagnosticLogHandler(label: $0, sink: sink) })
        let session = UUID().uuidString
        logger.notice("private content", metadata: ["event": "recording_auto_stopped", "session": "\(session)",
                                                    "auto_stop": "silence", "elapsed_ms": "61000"])
        logger.notice("private content", metadata: ["event": "recording_auto_stopped", "auto_stop": "private content"])
        sink.flush()
        let lines = try String(contentsOf: root.appendingPathComponent("diagnostics.jsonl"), encoding: .utf8)
        let rows = try lines.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String])
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["event"], "recording_auto_stopped")
        XCTAssertEqual(rows[0]["auto_stop"], "silence")
        XCTAssertEqual(rows[0]["session"], session)
        XCTAssertEqual(rows[0]["elapsed_ms"], "61000")
        XCTAssertNil(rows[1]["auto_stop"])
        XCTAssertFalse(lines.contains("private content"))
    }
}
