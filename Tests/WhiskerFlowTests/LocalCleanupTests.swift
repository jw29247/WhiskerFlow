import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

private struct StubDictationCleaner: DictationCleaning {
    let output: String
    var delay: UInt64 = 0
    var fails = false
    func clean(_ request: DictationCleanupRequest) async throws -> String {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if fails { throw LocalCleanupError.invalidOutput }
        return output
    }
}

private actor InspectingDictationCleaner: DictationCleaning {
    private(set) var inputs: [String] = []
    private(set) var correctionChoices: [Bool] = []
    func clean(_ request: DictationCleanupRequest) async throws -> String {
        inputs.append(request.text)
        correctionChoices.append(request.recognizeCorrections)
        return "send WhiskerFlow on Thursday"
    }
}

final class LocalCleanupTests: XCTestCase {
    @MainActor
    func testCleanupIsOnByDefaultAndExplicitChoicesPersist() {
        let suite = "cleanup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: suite))
        XCTAssertTrue(settings.localCleanupEnabled)
        settings.localCleanupEnabled = false
        XCTAssertFalse(AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: suite)).localCleanupEnabled)
        settings.localCleanupEnabled = true
        XCTAssertTrue(AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: suite)).localCleanupEnabled)
    }

    @MainActor
    func testSuccessfulCleanupAndFailuresKeepTheUsualText() async {
        let request = DictationCleanupRequest(text: "um send it Tuesday sorry Thursday")
        let success = LocalCleanupController(cleaner: StubDictationCleaner(output: "Send it Thursday."))
        let cleaned = await success.clean(request, fallback: "Usual text")
        XCTAssertTrue(cleaned.applied)
        XCTAssertEqual(cleaned.text, "Send it Thursday.")
        for cleaner in [StubDictationCleaner(output: ""), StubDictationCleaner(output: "ignored", fails: true)] {
            let result = await LocalCleanupController(cleaner: cleaner).clean(request, fallback: "Usual text")
            XCTAssertFalse(result.applied)
            XCTAssertEqual(result.text, "Usual text")
        }
    }

    @MainActor
    func testDeadlineKeepsTheUsualTextAndReleasesTheUI() async {
        let cleanup = LocalCleanupController(cleaner: StubDictationCleaner(output: "Late", delay: 1_000_000_000))
        let result = await cleanup.clean(.init(text: "Keep this"), fallback: "Keep this", deadline: 0.01)
        XCTAssertFalse(result.applied)
        XCTAssertEqual(result.text, "Keep this")
        XCTAssertFalse(cleanup.isCleaning)
        XCTAssertTrue(result.message.contains("too long"))
    }

    @MainActor
    func testPreviewUsesDictionaryAndToneWithoutChangingDisabledPreference() async {
        let suite = "cleanup-preview-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: suite))
        settings.localCleanupEnabled = false
        let cleaner = InspectingDictationCleaner()
        let cleanup = LocalCleanupController(cleaner: cleaner)
        let dictionary = DictionaryStore(legacyVocabulary: .init(rules: [.init(find: "whisker flow", replaceWith: "WhiskerFlow")]))
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(settings: settings, store: TranscriptStore(fileURL: storeURL), dictionaryStore: dictionary, localCleanup: cleanup)
        let output = await state.previewLocalCleanup("um send whisker flow on Tuesday sorry Thursday")
        XCTAssertEqual(output, "Send WhiskerFlow on Thursday.")
        let inputs = await cleaner.inputs
        XCTAssertEqual(inputs, ["um send WhiskerFlow on Tuesday sorry Thursday"])
        XCTAssertFalse(settings.localCleanupEnabled)
        XCTAssertTrue(state.records.isEmpty, "A preview does not create history or paste")
    }

    @MainActor
    func testRetranscriptionUsesOptInAndLiteralBypassAndPreservesRawRecognition() async throws {
        for (enabled, tone, corrections, expectedCalls) in [
            (false, WritingTone.formal, true, 0), (true, .formal, true, 1),
            (true, .literal, true, 0), (true, .formal, false, 1)
        ] {
            let suite = "cleanup-integration-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let audio = root.appendingPathComponent("test.wav")
            try Data().write(to: audio)
            let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: suite))
            settings.localCleanupEnabled = enabled
            settings.translateToEnglish = false
            let cleaner = InspectingDictationCleaner()
            let store = TranscriptStore(fileURL: root.appendingPathComponent("history.json"))
            let record = TranscriptRecord(text: "Earlier result", audioFilePath: audio.path, status: .transcribed)
            try store.add(record)
            let raw = "send WhiskerFlow on Tuesday sorry Thursday"
            let transcription = TranscriptionService(recognizerOverride: { _, _ in .init(text: raw) })
            let state = AppState(settings: settings, store: store, transcription: transcription,
                                 localCleanup: LocalCleanupController(cleaner: cleaner))
            state.assistant.editWritingStyles { $0.setTone(tone, for: .other) }
            state.assistant.setRecognizeCorrections(corrections)
            state.retranscribe(record, with: .parakeetTDTv3)
            for _ in 0..<200 {
                if !state.isTranscribing { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(state.isTranscribing)
            let inputs = await cleaner.inputs
            XCTAssertEqual(inputs.count, expectedCalls)
            let choices = await cleaner.correctionChoices
            XCTAssertEqual(choices, Array(repeating: corrections, count: expectedCalls))
            XCTAssertEqual(store.records.first?.rawRecognition, raw)
            if expectedCalls == 1 { XCTAssertEqual(store.records.first?.text, "Send WhiskerFlow on Thursday.") }
            if tone == .literal { XCTAssertEqual(store.records.first?.text, raw) }
        }
    }

    /// Run manually after downloading the model in Settings. No audio, account,
    /// Accessibility access or production history is needed.
    func testRealSmallModelCleanup() async throws {
        guard ProcessInfo.processInfo.environment["WHISKERFLOW_CLEANUP_PROBE"] == "1" else { throw XCTSkip("Opt-in real-model probe") }
        guard LocalCleanupModel.isDownloaded() else { throw XCTSkip("Download the cleanup model first") }
        let engine = LocalCleanupEngine()
        try await engine.prepare(modelURL: LocalCleanupModel.fileURL)
        let result = try await engine.clean(.init(text: "um please send Sarah the proposal on Tuesday sorry Thursday"))
        print("CLEANUP PROBE: \(result)")
        XCTAssertTrue(result.contains("Sarah"))
        XCTAssertTrue(result.lowercased().contains("thursday"))
        XCTAssertFalse(result.lowercased().contains("tuesday"))
        let preserved = try await engine.clean(.init(text: "um please send Sarah the proposal on Tuesday sorry Thursday", recognizeCorrections: false))
        XCTAssertTrue(preserved.lowercased().contains("tuesday"))
        XCTAssertTrue(preserved.lowercased().contains("thursday"))
    }
}
