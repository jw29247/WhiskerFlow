import AppKit
import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

@MainActor
private final class RecordingDeliveryService: TextDeliveryService {
    var hasAccessibilityPermission = true
    var pastes: [String] = []
    var copies: [String] = []
    func requestAccessibilityPermission() {}
    func copy(_ text: String) { copies.append(text) }
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?) async -> PasteDeliveryReceipt {
        pastes.append(text)
        return PasteDeliveryReceipt(state: .verified, text: text, message: "Pasted")
    }
}

/// A toggle recording that stopped itself is transcribed into History but never
/// pasted: nobody may be at the keyboard. Drives the post-capture path with a
/// fake recognizer and no microphone.
final class ToggleAutoStopDeliveryTests: XCTestCase {
    private struct Harness {
        let state: AppState
        let paste: RecordingDeliveryService
        let audio: URL
        let cleanUp: () -> Void
    }

    @MainActor
    private func makeHarness(delivery: DeliveryMode = .pasteAtCursor, retention: HistoryRetention = .defaultValue,
                             recognizer: @escaping @Sendable () throws -> String) throws -> Harness {
        let name = "WhiskerFlow.toggle-auto-stop-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        settings.recordingMode = .toggle
        settings.allowAppleFallback = false
        settings.cleanupEnabled = false
        settings.delivery = delivery
        settings.historyRetention = retention
        settings.playSounds = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("capture.wav")
        try Data(count: 44 + 32_000).write(to: audio)
        let store = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        let paste = RecordingDeliveryService()
        let transcription = TranscriptionService(recognizerOverride: { _, _ in TranscriptionResult(text: try recognizer()) })
        let state = AppState(settings: settings, store: store, pasteService: paste, transcription: transcription)
        return Harness(state: state, paste: paste, audio: audio) {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A second of a clear tone: not judged silent by the pre-recognition check.
    private let speech: [Float] = (0..<16_000).map { 0.2 * sin(Float($0) * 0.05) }
    /// A recording past the silence limit: only its last 30 s are resident.
    private let resident: [Float] = Array(repeating: 0, count: 16_000 * 30)

    @MainActor
    func testSilenceStopSavesToHistoryWithoutPasting() async throws {
        let harness = try makeHarness { "Notes from the planning call." }
        defer { harness.cleanUp() }
        await harness.state.completeCaptureForTesting(samples: resident, totalSampleCount: 16_000 * 75,
                                                      audioURL: harness.audio, stopReason: .autoStopped(.silence))

        let record = try XCTUnwrap(harness.state.records.first)
        XCTAssertEqual(record.status, .transcribed)
        XCTAssertTrue(record.text.contains("planning call"))
        XCTAssertTrue(harness.paste.pastes.isEmpty, "An automatic stop must never paste")
        XCTAssertTrue(harness.paste.copies.isEmpty, "Paste delivery does not fall back to the clipboard")
        let message = "Stopped after a minute of silence. Your text is in History."
        XCTAssertEqual(harness.state.status, .success(message))
        XCTAssertEqual(harness.state.autoStopNotice, AutoStopNotice(message: message, recordID: record.id))
        XCTAssertEqual(harness.state.hudPresentation, .notification(message))
    }

    @MainActor
    func testMaximumLengthStopWithCopyOnlyCopiesAsUsual() async throws {
        let harness = try makeHarness(delivery: .copyOnly) { "A very long dictation." }
        defer { harness.cleanUp() }
        await harness.state.completeCaptureForTesting(samples: resident, totalSampleCount: 16_000 * 1_800,
                                                      audioURL: harness.audio, stopReason: .autoStopped(.maximumLength))

        let record = try XCTUnwrap(harness.state.records.first)
        XCTAssertEqual(record.status, .transcribed)
        XCTAssertTrue(harness.paste.pastes.isEmpty)
        XCTAssertEqual(harness.paste.copies.count, 1)
        XCTAssertEqual(harness.state.status,
                       .success("Stopped after 30 minutes. Your text is in History and on the clipboard."))
    }

    /// "Don't save history" prunes the transcript as soon as it is written, so
    /// the clipboard is the only place the text can go.
    @MainActor
    func testWithHistoryOffTheTextGoesToTheClipboardInstead() async throws {
        let harness = try makeHarness(retention: .off) { "Ideas for the workshop." }
        defer { harness.cleanUp() }
        await harness.state.completeCaptureForTesting(samples: resident, totalSampleCount: 16_000 * 75,
                                                      audioURL: harness.audio, stopReason: .autoStopped(.silence))

        XCTAssertTrue(harness.state.records.isEmpty, "History is off, so nothing is kept")
        XCTAssertTrue(harness.paste.pastes.isEmpty, "An automatic stop must never paste")
        XCTAssertEqual(harness.paste.copies, ["Ideas for the workshop."])
        let message = "Stopped after a minute of silence. Your text is on the clipboard."
        XCTAssertEqual(harness.state.status, .success(message))
        XCTAssertEqual(harness.state.autoStopNotice, AutoStopNotice(message: message, recordID: nil))
    }

    @MainActor
    func testRecordingWithNothingSaidIsDiscardedQuietly() async throws {
        let harness = try makeHarness { throw TranscriptionError.emptyTranscript }
        defer { harness.cleanUp() }
        await harness.state.completeCaptureForTesting(samples: resident, totalSampleCount: 16_000 * 61,
                                                      audioURL: harness.audio, stopReason: .autoStopped(.noSpeech))

        XCTAssertTrue(harness.state.records.isEmpty, "No History entry and nothing to retry")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.audio.path), "The audio is discarded")
        XCTAssertTrue(harness.paste.pastes.isEmpty)
        XCTAssertTrue(harness.paste.copies.isEmpty)
        XCTAssertEqual(harness.state.status, .success("Stopped after a minute of silence. Nothing was said."))
        XCTAssertNil(harness.state.lastError)
    }

    /// A manual stop a moment before the limit is an ordinary dictation.
    @MainActor
    func testManualStopBeforeTheLimitPastesAsToday() async throws {
        let harness = try makeHarness { "Send the draft today." }
        defer { harness.cleanUp() }
        await harness.state.completeCaptureForTesting(samples: speech, audioURL: harness.audio, stopReason: .userReleased)

        XCTAssertEqual(harness.state.records.first?.status, .transcribed)
        XCTAssertEqual(harness.paste.pastes.count, 1)
        XCTAssertEqual(harness.state.status, .success("Pasted"))
        XCTAssertNil(harness.state.autoStopNotice)
    }
}
