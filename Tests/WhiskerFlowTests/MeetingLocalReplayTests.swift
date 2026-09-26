import XCTest
@testable import WhiskerFlow
import WhiskerFlowAppSupport

/// Explicit local-only diagnostic. Never records, uploads, or mutates retained sessions.
final class MeetingLocalReplayTests: XCTestCase {
    func testRetainedLocalRecordingCanBeProcessed() async throws {
        guard let raw = ProcessInfo.processInfo.environment["WHISKERFLOW_LOCAL_REPLAY_SESSION"],
              let id = UUID(uuidString: raw) else {
            throw XCTSkip("Opt-in local recording replay")
        }
        let root = StorageLocations.applicationSupportRootOrTemporary().appendingPathComponent("MeetingRecordings")
        let store = EncryptedMeetingChunkStore(rootURL: root, keyProvider: KeychainMeetingChunkKeyProvider())
        var manifest = try store.loadManifest(sessionID: id)
        if let rawLimit = ProcessInfo.processInfo.environment["WHISKERFLOW_LOCAL_REPLAY_MAX_MS"],
           let limit = Int64(rawLimit), limit > 0 {
            manifest.chunks = manifest.chunks.filter { $0.endMs <= limit }
        }
        if let rawStart = ProcessInfo.processInfo.environment["WHISKERFLOW_LOCAL_REPLAY_MIN_MS"], let start = Int64(rawStart) {
            manifest.chunks = manifest.chunks.filter { $0.startMs >= start }
        }
        for track in [MeetingAudioTrack.microphone, .system, .mixed] {
            var count = 0
            var sumSquares = 0.0
            var peak = 0.0
            for chunk in manifest.chunks where chunk.track == track {
                let data = try store.readChunk(sessionID: id, descriptor: chunk)
                data.withUnsafeBytes { bytes in
                    for value in bytes.bindMemory(to: Float.self) where value.isFinite {
                        count += 1
                        sumSquares += Double(value) * Double(value)
                        peak = max(peak, abs(Double(value)))
                    }
                }
            }
            let rms = count > 0 ? sqrt(sumSquares / Double(count)) : 0
            print("LOCAL_REPLAY_AUDIO: track=\(track.rawValue), samples=\(count), rms=\(rms), peak=\(peak)")
        }
        if ProcessInfo.processInfo.environment["WHISKERFLOW_LOCAL_REPLAY_AUDIO_ONLY"] == "1" { return }
        print("LOCAL_REPLAY: decrypted \(manifest.chunks.count) chunks")
        let replayRoot = FileManager.default.temporaryDirectory.appendingPathComponent("WhiskerFlowReplay-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: replayRoot) }
        let result: MeetingLocalProcessingResult
        do {
            result = try await MeetingLocalProcessor(transcription: TranscriptionService(), processingRoot: replayRoot).process(manifest: manifest, store: store, language: "en", resumable: false)
        } catch let error as MeetingWindowTranscriptionFailure {
            print("LOCAL_REPLAY_FAILED_WINDOW: track=\(error.track.rawValue), start_ms=\(error.startMs), end_ms=\(error.endMs)")
            throw error
        }
        XCTAssertFalse(result.turns.isEmpty, "A recorded meeting needs transcript turns before delivery")
        for turn in result.turns {
            print("LOCAL_REPLAY_TIMING: start_ms=\(turn.startMs), end_ms=\(turn.endMs), resolution=\(turn.speaker.resolution.rawValue)")
        }
        let resolutions = Dictionary(grouping: result.turns, by: { $0.speaker.resolution.rawValue }).mapValues(\.count)
        let speakers = Set(result.turns.map { $0.speaker.key }).count
        print("LOCAL_REPLAY: speaker_count=\(speakers), resolutions=\(resolutions)")
        print("LOCAL_REPLAY: processed \(result.turns.count) turns, \(result.durationMs)ms")
    }
}
