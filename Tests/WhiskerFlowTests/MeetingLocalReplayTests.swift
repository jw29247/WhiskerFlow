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
        let manifest = try store.loadManifest(sessionID: id)
        for chunk in manifest.chunks { _ = try store.readChunk(sessionID: id, descriptor: chunk) }
        print("LOCAL_REPLAY: decrypted \(manifest.chunks.count) chunks")
        let result = try await MeetingLocalProcessor(transcription: TranscriptionService()).process(manifest: manifest, store: store, language: "en")
        XCTAssertFalse(result.turns.isEmpty, "A recorded meeting needs transcript turns before delivery")
        print("LOCAL_REPLAY: processed \(result.turns.count) turns, \(result.durationMs)ms")
    }
}
