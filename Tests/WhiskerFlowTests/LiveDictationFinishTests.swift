import AppKit
import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

final class LiveDictationFinishTests: XCTestCase {
    func testRecognitionBackstopSitsAboveTheEngineDecodeBudget() {
        for seconds in [1.0, 10, 60, 600] {
            XCTAssertGreaterThan(
                AppState.recognitionBackstopSeconds(forAudioSeconds: seconds),
                DecodeTimeoutPolicy.timeout(forAudioSeconds: seconds) * 2
            )
        }
        XCTAssertGreaterThan(
            AppState.recognitionBackstopSeconds(forAudioSeconds: nil),
            DecodeTimeoutPolicy.maximumTimeout
        )
    }

    func testAudioDurationIsEstimatedFromTheWAVSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 44 + 32_000 * 3).write(to: url)
        XCTAssertEqual(try XCTUnwrap(AppState.estimatedAudioSeconds(of: url)), 3, accuracy: 0.001)
    }
}

@MainActor
private final class CountingDeliveryService: TextDeliveryService {
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

final class RetryDeliveryTests: XCTestCase {
    /// Retries finish long after their dictation; pasting then would drop an old
    /// transcript into whatever app happens to be frontmost.
    @MainActor
    func testRetryAllUpdatesHistoryWithoutPastingOrCopying() async throws {
        let name = "WhiskerFlow.retry-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        settings.allowAppleFallback = false
        settings.delivery = .pasteAtCursor
        settings.playSounds = false

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        for index in 0..<2 {
            let audio = root.appendingPathComponent("\(index).wav")
            try Data(count: 44 + 32_000).write(to: audio)
            try store.add(TranscriptRecord(text: "", audioFilePath: audio.path, status: .failed(errorMessage: "Timed out")))
        }
        let paste = CountingDeliveryService()
        let state = AppState(settings: settings, store: store, pasteService: paste,
                             transcription: FakeRecognizer(text: "Retried transcript").service)
        state.records = store.records

        state.retryAllFailed()
        let deadline = Date().addingTimeInterval(20)
        while state.records.contains(where: { $0.status != .transcribed }), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(state.records.map(\.status), [.transcribed, .transcribed])
        XCTAssertEqual(state.records.map(\.text), ["Retried transcript", "Retried transcript"])
        XCTAssertTrue(paste.pastes.isEmpty, "A retry must never paste")
        XCTAssertTrue(paste.copies.isEmpty, "A retry must not overwrite the clipboard")
        XCTAssertEqual(state.status, .success("Retry saved to History"))
    }

    /// A quick capture whose first transcription failed finishes as the draft
    /// it was recorded for, not as dictation: nothing is pasted or copied.
    @MainActor
    func testRetriedQuickCaptureBecomesItsDraft() async throws {
        let name = "WhiskerFlow.retry-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        settings.allowAppleFallback = false
        settings.delivery = .pasteAtCursor
        settings.playSounds = false

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        let audio = root.appendingPathComponent("capture.wav")
        try Data(count: 44 + 32_000).write(to: audio)
        let record = TranscriptRecord(text: "", audioFilePath: audio.path, status: .failed(errorMessage: "Timed out"),
                                      captureIntent: TranscriptCaptureIntent(purpose: .quickCapture, quickKind: .taskDraft))
        try store.add(record)
        let paste = CountingDeliveryService()
        let state = AppState(settings: settings, store: store, pasteService: paste,
                             transcription: FakeRecognizer(text: "Book the venue").service)
        state.records = store.records

        state.retry(record)
        let deadline = Date().addingTimeInterval(20)
        while state.records.contains(where: { $0.status != .transcribed }), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(state.assistant.saved.drafts.map(\.kind), [.taskDraft])
        XCTAssertEqual(state.assistant.saved.drafts.first?.text.contains("Book the venue"), true)
        XCTAssertTrue(paste.pastes.isEmpty, "A retry must never paste")
        XCTAssertTrue(paste.copies.isEmpty, "A retry must not overwrite the clipboard")
    }
}
