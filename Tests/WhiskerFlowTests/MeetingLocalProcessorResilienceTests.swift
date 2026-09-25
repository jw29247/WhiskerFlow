import CryptoKit
import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport
import WhiskerFlowCore

final class MeetingLocalProcessorResilienceTests: XCTestCase {
    func testNonSpeechAudibleWindowBecomesAGapInsteadOfFailingTheMeeting() async throws {
        // Six 10 s chunks form three 30 s windows (with one chunk of overlap).
        // The first chunk is hold music: audible, but Whisper never finds speech.
        let (store, id, root) = try fixture(tracks: [.mixed], chunks: 7, amplitude: 0.1)
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = MeetingLocalProcessor(processingRoot: root.appendingPathComponent("processing")) { url, _ in
            let name = url.lastPathComponent
            if name.contains("mixed-0") { throw TranscriptionError.emptyTranscript }
            return TranscriptionResult(text: "Speech", segments: [.init(text: "Speech", start: 15, end: 16)])
        }
        let result = try await processor.process(manifest: store.loadManifest(sessionID: id), store: store, language: "en")
        XCTAssertFalse(result.turns.isEmpty)
        XCTAssertEqual(result.untranscribedAudibleWindowCount, 1)
    }

    func testMostlyUndecodableAudioStillFailsAndKeepsTheRecording() async throws {
        let (store, id, root) = try fixture(tracks: [.mixed], chunks: 3, amplitude: 0.1)
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = MeetingLocalProcessor(processingRoot: root.appendingPathComponent("processing")) { _, _ in
            throw TranscriptionError.emptyTranscript
        }
        do {
            _ = try await processor.process(manifest: store.loadManifest(sessionID: id), store: store, language: "en")
            XCTFail("A decoder that returns nothing for every audible window must not produce an empty transcript")
        } catch is MeetingWindowTranscriptionFailure {}
    }

    func testSilentRecordingIsAnEmptyResultNotARetryableError() async throws {
        let (store, id, root) = try fixture(tracks: [.mixed, .microphone], chunks: 2, amplitude: 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = MeetingLocalProcessor(processingRoot: root.appendingPathComponent("processing")) { _, _ in
            throw TranscriptionError.emptyTranscript
        }
        let result = try await processor.process(manifest: store.loadManifest(sessionID: id), store: store, language: "en")
        XCTAssertTrue(result.turns.isEmpty)
    }

    func testOneFailedMicrophoneWindowKeepsTheRestOfTheSelfEvidence() async throws {
        let (store, id, root) = try fixture(tracks: [.mixed, .microphone], chunks: 4, amplitude: 0.1)
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = MeetingLocalProcessor(processingRoot: root.appendingPathComponent("processing")) { url, _ in
            let name = url.lastPathComponent
            // The second microphone window is keyboard noise and never decodes.
            if name.contains("microphone-1") { throw TranscriptionError.emptyTranscript }
            if name.contains("mixed-1") || name.contains("microphone-1") {
                return TranscriptionResult(text: "Remote", segments: [.init(text: "Remote", start: 12, end: 14)])
            }
            return TranscriptionResult(text: "My update is ready", segments: [.init(text: "My update is ready", start: 1, end: 4)])
        }
        let result = try await processor.process(manifest: store.loadManifest(sessionID: id), store: store, language: "en")
        XCTAssertEqual(result.turns.first?.speaker, .microphone)
        XCTAssertNotEqual(result.turns.last?.speaker, .microphone)
    }

    func testSelfMatchToleratesPunctuationBoundariesAndBackchannel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let processor = MeetingLocalProcessor(processingRoot: root) { _, _ in TranscriptionResult(text: "") }
        let mixed = TranscriptionSegment(text: "Yeah, so the plan is, we ship Friday. OK.", start: 10, end: 14)
        let mic = [
            TranscriptionSegment(text: "yeah so the plan is", start: 9.8, end: 12),
            TranscriptionSegment(text: "we ship friday", start: 12, end: 13.6),
        ]
        let matchesMic = await processor.matchesSelf(mixed, in: mic)
        XCTAssertTrue(matchesMic)
        let remote = TranscriptionSegment(text: "Can you share the budget numbers", start: 10, end: 14)
        let matchesRemote = await processor.matchesSelf(remote, in: mic)
        XCTAssertFalse(matchesRemote)
        let matchesSilence = await processor.matchesSelf(mixed, in: [])
        XCTAssertFalse(matchesSilence)
    }

    func testInterruptedProcessingResumesAfterTheLastCompletedWindow() async throws {
        let (store, id, root) = try fixture(tracks: [.mixed], chunks: 7, amplitude: 0.1)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoded = Counter()
        let interrupted = MeetingLocalProcessor(processingRoot: root.appendingPathComponent("processing")) { url, _ in
            if url.lastPathComponent.contains("mixed-2") { throw CancellationError() }
            await decoded.increment()
            return TranscriptionResult(text: "Window", segments: [.init(text: "Window \(url.lastPathComponent.contains("mixed-0") ? 0 : 1)", start: 21, end: 22)])
        }
        do {
            _ = try await interrupted.process(manifest: store.loadManifest(sessionID: id), store: store, language: "en")
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let decodedBefore = await decoded.value
        XCTAssertEqual(decodedBefore, 2)

        let resumedDecodes = Counter()
        let resumed = MeetingLocalProcessor(processingRoot: root.appendingPathComponent("processing")) { url, _ in
            XCTAssertTrue(url.lastPathComponent.contains("mixed-2"), "Completed windows must not be decoded again")
            await resumedDecodes.increment()
            return TranscriptionResult(text: "Final", segments: [.init(text: "Final window", start: 21, end: 22)])
        }
        let result = try await resumed.process(manifest: store.loadManifest(sessionID: id), store: store, language: "en")
        let resumedCount = await resumedDecodes.value
        XCTAssertEqual(resumedCount, 1)
        XCTAssertEqual(result.turns.map(\.text), ["Window 0", "Window 1", "Final window"])
    }

    func testTransientDecoderTimeoutIsRetriedForThatWindow() async throws {
        let (store, id, root) = try fixture(tracks: [.mixed], chunks: 1, amplitude: 0.1)
        defer { try? FileManager.default.removeItem(at: root) }
        let attempts = Counter()
        let processor = MeetingLocalProcessor(
            processingRoot: root.appendingPathComponent("processing"),
            transcribeMeeting: { _, _ in
                await attempts.increment()
                if await attempts.value == 1 { throw TranscriptionError.timedOut(seconds: 105) }
                return TranscriptionResult(text: "Recovered", segments: [.init(text: "Recovered", start: 0, end: 1)])
            },
            transientRetryUnitNanoseconds: 1_000
        )
        let result = try await processor.process(manifest: store.loadManifest(sessionID: id), store: store, language: "en")
        XCTAssertEqual(result.turns.map(\.text), ["Recovered"])
    }

    private func fixture(tracks: [MeetingAudioTrack], chunks: Int, amplitude: Float) throws -> (EncryptedMeetingChunkStore, UUID, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = EncryptedMeetingChunkStore(rootURL: root.appendingPathComponent("recordings"), keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256)))
        let id = UUID()
        try store.beginSession(sessionID: id, meetingID: nil, expectedChunkCounts: Dictionary(uniqueKeysWithValues: tracks.map { ($0, chunks) }))
        let samples = [Float](repeating: amplitude, count: 160_000)
        for track in tracks {
            for sequence in 0..<chunks {
                _ = try store.writeChunk(
                    sessionID: id, track: track, sequence: sequence,
                    startMs: Int64(sequence * 10_000), endMs: Int64((sequence + 1) * 10_000),
                    plaintext: samples.withUnsafeBufferPointer { Data(buffer: $0) })
            }
        }
        return (store, id, root)
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
