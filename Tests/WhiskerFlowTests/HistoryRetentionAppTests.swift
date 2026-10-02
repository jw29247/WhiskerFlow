import AppKit
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

private final class RecordingDeliveryService: TextDeliveryService {
    var hasAccessibilityPermission = true
    var copies: [String] = []
    func requestAccessibilityPermission() {}
    func copy(_ text: String) { copies.append(text) }
    func paste(_ text: String, into application: NSRunningApplication?, replacing selection: TextFieldSnapshot?) async -> PasteDeliveryReceipt {
        PasteDeliveryReceipt(state: .verified, text: text, message: "Pasted")
    }
}

final class HistoryRetentionAppTests: XCTestCase {
    @MainActor
    private func makeSettings(_ name: String) throws -> (AppSettings, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name)), defaults)
    }

    @MainActor
    func testNewAndExistingInstallsStartAtNinetyDaysAndKeepAChoice() throws {
        let name = "WhiskerFlow.retention-tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let (settings, defaults) = try makeSettings(name)
        XCTAssertEqual(settings.historyRetention, .ninetyDays)
        XCTAssertEqual(defaults.string(forKey: "historyRetention"), "ninetyDays", "the migrated value is written through")
        XCTAssertEqual(settings.typingWordsPerMinute, 40)

        settings.historyRetention = .forever
        settings.typingWordsPerMinute = 65
        let relaunched = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        XCTAssertEqual(relaunched.historyRetention, .forever)
        XCTAssertEqual(relaunched.typingWordsPerMinute, 65)
    }

    /// With history off, a finished transcription is counted in Insights and
    /// stays copyable from memory, but nothing is left in History.
    @MainActor
    func testDontSaveHistoryStillCountsAndKeepsALastTranscriptInMemory() async throws {
        let name = "WhiskerFlow.retention-tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let (settings, _) = try makeSettings(name)
        settings.allowAppleFallback = false
        settings.playSounds = false

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        let audio = root.appendingPathComponent("0.wav")
        try Data(count: 44 + 32_000).write(to: audio)
        try store.add(TranscriptRecord(text: "", audioFilePath: audio.path, status: .failed(errorMessage: "Timed out")))
        let insights = InsightsStore(databaseURL: root.appendingPathComponent("insights.sqlite"))
        let state = AppState(settings: settings, store: store, insightsStore: insights, pasteService: RecordingDeliveryService(),
                             transcription: FakeRecognizer(text: "Private words").service)
        state.records = store.records
        state.setHistoryRetention(.off)
        XCTAssertEqual(state.records.count, 1, "a failed recording stays retryable with history off")

        state.retryAllFailed()
        let deadline = Date().addingTimeInterval(20)
        while (state.insightsSummary.lifetimeDictations == 0 || !state.records.isEmpty), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(state.records.isEmpty)
        XCTAssertEqual(state.latestTranscript?.text, "Private words")
        XCTAssertEqual(state.recentTranscripts(limit: 3).map(\.text), ["Private words"])
        XCTAssertEqual(state.insightsSummary.lifetimeDictations, 1)
        XCTAssertEqual(state.insightsSummary.lifetimeWords, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), "a transcribed recording's audio goes with it")

        let reloaded = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"), retention: .forever)
        try reloaded.load()
        XCTAssertTrue(reloaded.records.isEmpty, "no transcript text reaches disk")
    }

    @MainActor
    func testShorteningRetentionDeletesOnlyWhatTheCountPromised() throws {
        let name = "WhiskerFlow.retention-tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let (settings, _) = try makeSettings(name)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"), retention: .forever,
                                    removeAudioFile: { _ in })
        let day: TimeInterval = 86_400
        try store.replaceAll([2, 10, 40, 400].map {
            TranscriptRecord(text: "record", audioFilePath: "", createdAt: Date().addingTimeInterval(-$0 * day), status: .transcribed)
        })
        let state = AppState(settings: settings, store: store, pasteService: RecordingDeliveryService())
        state.records = store.records

        XCTAssertEqual(state.historyRemovalCount(for: .sevenDays), 3)
        state.setHistoryRetention(.thirtyDays)
        XCTAssertEqual(state.records.count, 2)
        XCTAssertEqual(settings.historyRetention, .thirtyDays)
    }

    @MainActor
    func testRetryWithAnotherEngineReplacesOnlyOnSuccess() async throws {
        let name = "WhiskerFlow.retention-tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let (settings, _) = try makeSettings(name)
        settings.playSounds = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("saved.wav")
        try Data(count: 44 + 32_000).write(to: audio)
        let store = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        let original = TranscriptRecord(text: "Original words", audioFilePath: audio.path, status: .transcribed,
                                        durationSeconds: 1, engine: TranscriptionEngineKind.appleSpeech.rawValue)
        try store.add(original)
        let insights = InsightsStore(databaseURL: root.appendingPathComponent("insights.sqlite"))
        let recognizer = FakeRecognizer(text: nil)
        let state = AppState(settings: settings, store: store, insightsStore: insights, pasteService: RecordingDeliveryService(),
                             transcription: recognizer.service)
        state.records = store.records
        XCTAssertTrue(state.hasRecording(original))

        state.retranscribe(original, with: .parakeetTDTv3)
        var deadline = Date().addingTimeInterval(20)
        while state.isTranscribing || state.status == .transcribing, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(state.records.first?.text, "Original words", "a failed retry keeps the transcript")
        XCTAssertEqual(state.records.first?.status, .transcribed)

        recognizer.text = "From the other engine"
        state.retranscribe(original, with: .parakeetTDTv3)
        deadline = Date().addingTimeInterval(20)
        while state.records.first?.text == "Original words", Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        // The writing tone may add end punctuation; the words come from the other engine.
        XCTAssertTrue(state.records.first?.text.hasPrefix("From the other engine") == true)
        XCTAssertEqual(state.records.first?.engine, TranscriptionEngineKind.parakeetTDTv3.rawValue)
        XCTAssertTrue(state.insightsSummary.isEmpty, "a re-transcription is not a new dictation")
    }
}

/// Stands in for the recogniser: returns `text`, or fails while it is nil.
final class FakeRecognizer: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?

    init(text: String?) { current = text }

    var text: String? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var service: TranscriptionService {
        TranscriptionService(recognizerOverride: { [self] _, _ in
            guard let text else { throw TranscriptionError.underlying("Recogniser unavailable") }
            return TranscriptionResult(text: text)
        })
    }
}
