import CryptoKit
import XCTest
@testable import WhiskerFlowAppSupport

final class MeetingCaptureTests: XCTestCase {
    func testEncryptedChunkRoundTripsAndRecoveryIgnoresPartialFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whiskerflow-meeting-tests-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let key = SymmetricKey(size: .bits256)
        let store = EncryptedMeetingChunkStore(
            rootURL: root,
            keyProvider: FixedMeetingChunkKeyProvider(key: key)
        )
        let sessionID = UUID()
        _ = try store.beginSession(
            sessionID: sessionID,
            meetingID: "meeting-1",
            expectedChunkCounts: [.microphone: 1, .mixed: 1]
        )

        let descriptor = try store.writeChunk(
            sessionID: sessionID,
            track: .microphone,
            sequence: 0,
            startMs: 0,
            endMs: 1_000,
            plaintext: Data("mic-audio".utf8)
        )
        XCTAssertFalse(descriptor.relativePath.hasSuffix(".partial"))
        XCTAssertEqual(
            try store.readChunk(sessionID: sessionID, descriptor: descriptor),
            Data("mic-audio".utf8)
        )

        let partial = root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("system-00000001-1000-2000-deadbeef.wfchunk.partial")
        try Data("unfinished".utf8).write(to: partial)

        let recovered = try store.recoverSessions()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].chunks, [descriptor])
    }

    func testChunkManifestIsIdempotentForExistingSequence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whiskerflow-meeting-tests-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = EncryptedMeetingChunkStore(
            rootURL: root,
            keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))
        )
        let sessionID = UUID()
        _ = try store.beginSession(
            sessionID: sessionID,
            meetingID: nil,
            expectedChunkCounts: [.mixed: 1]
        )
        let first = try store.writeChunk(
            sessionID: sessionID,
            track: .mixed,
            sequence: 0,
            startMs: 0,
            endMs: 1_000,
            plaintext: Data("audio".utf8)
        )
        let second = try store.writeChunk(
            sessionID: sessionID,
            track: .mixed,
            sequence: 0,
            startMs: 0,
            endMs: 1_000,
            plaintext: Data("audio".utf8)
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(try store.loadManifest(sessionID: sessionID).chunks.count, 1)
    }

    func testChunkManifestGrowsBeyondTheInitialDurationForecast() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whiskerflow-meeting-tests-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = EncryptedMeetingChunkStore(
            rootURL: root,
            keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))
        )
        let sessionID = UUID()
        _ = try store.beginSession(
            sessionID: sessionID,
            meetingID: nil,
            expectedChunkCounts: [.mixed: 1]
        )

        _ = try store.writeChunk(
            sessionID: sessionID,
            track: .mixed,
            sequence: 0,
            startMs: 0,
            endMs: 1_000,
            plaintext: Data("first".utf8)
        )
        _ = try store.writeChunk(
            sessionID: sessionID,
            track: .mixed,
            sequence: 1,
            startMs: 1_000,
            endMs: 2_000,
            plaintext: Data("second".utf8)
        )

        let manifest = try store.loadManifest(sessionID: sessionID)
        XCTAssertEqual(manifest.expectedChunkCounts[.mixed], 2)
        XCTAssertEqual(manifest.chunks.count, 2)
    }

    func testSourceManifestChecksumIsStableAcrossUploadRetries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whiskerflow-meeting-tests-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = EncryptedMeetingChunkStore(
            rootURL: root,
            keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))
        )
        let sessionID = UUID()
        _ = try store.beginSession(
            sessionID: sessionID,
            meetingID: nil,
            expectedChunkCounts: [.mixed: 1]
        )
        let descriptor = try store.writeChunk(
            sessionID: sessionID,
            track: .mixed,
            sequence: 0,
            startMs: 0,
            endMs: 1_000,
            plaintext: Data("audio".utf8)
        )
        let beforeUpload = try store.sourceManifestChecksum(sessionID: sessionID)
        try store.markUploaded(sessionID: sessionID, track: descriptor.track, sequence: descriptor.sequence)
        XCTAssertEqual(beforeUpload, try store.sourceManifestChecksum(sessionID: sessionID))
    }

    func testSpeakerResolutionNeverInventsAName() {
        XCTAssertEqual(MeetingSpeakerIdentity.microphone.displayName, "You")
        XCTAssertEqual(
            MeetingSpeakerIdentity.diarized(key: "cluster-1", index: 1).displayName,
            "Speaker 1"
        )
        XCTAssertEqual(
            MeetingSpeakerIdentity.unknown(key: "cluster-2").displayName,
            "Unknown speaker"
        )
    }
}
