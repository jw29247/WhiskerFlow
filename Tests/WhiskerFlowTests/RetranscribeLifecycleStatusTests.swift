import Foundation
import WhiskerFlowAppSupport
import WhiskerFlowCore
import XCTest
@testable import WhiskerFlow

/// Holds recognition open until the test releases it, so a dictation can start
/// while a re-transcription is still decoding.
private final class GatedRecognizer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private let text: String?
    private let entered: @Sendable () -> Void

    init(text: String?, entered: @escaping @Sendable () -> Void) {
        self.text = text
        self.entered = entered
    }

    var service: TranscriptionService {
        TranscriptionService(recognizerOverride: { [self] _, _ in
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                entered()
            }
            guard let text else { throw TranscriptionError.underlying("Recogniser unavailable") }
            return TranscriptionResult(text: text)
        })
    }

    func release() {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

@MainActor
final class RetranscribeLifecycleStatusTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups = []
        super.tearDown()
    }

    private func makeState(recognizerText: String?) throws -> (AppState, TranscriptRecord, GatedRecognizer, XCTestExpectation) {
        let name = "WhiskerFlow.retranscribe-status-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanups.append {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let settings = AppSettings(defaults: defaults, meetingTokenStore: MeetingCaptureTokenStore(service: name))
        settings.allowAppleFallback = false
        settings.playSounds = false
        let store = TranscriptStore(fileURL: root.appendingPathComponent("transcripts.json"))
        let audio = root.appendingPathComponent("saved.wav")
        try Data(count: 44 + 32_000).write(to: audio)
        let record = TranscriptRecord(text: "Original words", audioFilePath: audio.path, status: .transcribed,
                                      durationSeconds: 1, engine: TranscriptionEngineKind.appleSpeech.rawValue)
        try store.add(record)
        let entered = expectation(description: "Re-transcription is decoding")
        let recognizer = GatedRecognizer(text: recognizerText) { entered.fulfill() }
        let state = AppState(settings: settings, store: store, transcription: recognizer.service)
        state.records = store.records
        return (state, record, recognizer, entered)
    }

    /// A dictation that starts while a History entry re-transcribes keeps its
    /// "Listening…" status; the new text still lands in History.
    func testRetranscriptionFinishingDuringRecordingKeepsTheLiveStatus() async throws {
        let (state, record, recognizer, entered) = try makeState(recognizerText: "From the other engine")
        let task = try XCTUnwrap(state.retranscribe(record, with: .parakeetTDTv3))
        await fulfillment(of: [entered], timeout: 5)

        state.holdLiveDictationForTesting(finishing: false)
        state.status = .recording
        recognizer.release()
        await task.value

        XCTAssertEqual(state.status, .recording)
        XCTAssertTrue(state.records.first?.text.hasPrefix("From the other engine") == true)
    }

    func testRetranscriptionFinishingWhileADictationTranscribesKeepsTheLiveStatus() async throws {
        let (state, record, recognizer, entered) = try makeState(recognizerText: "From the other engine")
        let task = try XCTUnwrap(state.retranscribe(record, with: .parakeetTDTv3))
        await fulfillment(of: [entered], timeout: 5)

        state.holdLiveDictationForTesting(finishing: true)
        state.status = .transcribing
        recognizer.release()
        await task.value

        XCTAssertEqual(state.status, .transcribing)
        XCTAssertTrue(state.records.first?.text.hasPrefix("From the other engine") == true)
    }

    func testFailedRetranscriptionDuringALiveDictationKeepsTheLiveStatus() async throws {
        let (state, record, recognizer, entered) = try makeState(recognizerText: nil)
        let task = try XCTUnwrap(state.retranscribe(record, with: .parakeetTDTv3))
        await fulfillment(of: [entered], timeout: 5)

        state.holdLiveDictationForTesting(finishing: false)
        state.status = .recording
        recognizer.release()
        await task.value

        XCTAssertEqual(state.status, .recording)
        XCTAssertEqual(state.records.first?.text, "Original words")
    }

    /// Started while another dictation is still finishing: it must not show
    /// "Transcribing…" over that dictation either.
    func testRetranscriptionStartedWhileADictationFinishesDoesNotTakeTheStatus() async throws {
        let (state, record, recognizer, entered) = try makeState(recognizerText: "From the other engine")
        state.holdLiveDictationForTesting(finishing: true)
        state.status = .success("Pasted")
        let task = try XCTUnwrap(state.retranscribe(record, with: .parakeetTDTv3))
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(state.status, .success("Pasted"))
        recognizer.release()
        await task.value
        XCTAssertEqual(state.status, .success("Pasted"))
    }

    func testWithNothingInProgressTheResultIsReportedAsBefore() async throws {
        let (state, record, recognizer, entered) = try makeState(recognizerText: "From the other engine")
        let task = try XCTUnwrap(state.retranscribe(record, with: .parakeetTDTv3))
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(state.status, .transcribing)
        recognizer.release()
        await task.value

        XCTAssertEqual(state.status, .success("Transcribed again with \(TranscriptionEngineKind.parakeetTDTv3.displayName)"))
        XCTAssertFalse(state.isTranscribing)
    }

    func testWithNothingInProgressAFailureIsReportedAsBefore() async throws {
        let (state, record, recognizer, entered) = try makeState(recognizerText: nil)
        let task = try XCTUnwrap(state.retranscribe(record, with: .parakeetTDTv3))
        await fulfillment(of: [entered], timeout: 5)
        recognizer.release()
        await task.value

        XCTAssertEqual(state.status, .failure(
            "\(TranscriptionEngineKind.parakeetTDTv3.displayName) couldn’t transcribe this recording. Your transcript is unchanged."))
    }
}
