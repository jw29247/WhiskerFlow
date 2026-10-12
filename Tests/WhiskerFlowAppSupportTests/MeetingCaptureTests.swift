import CryptoKit
import XCTest
@testable import WhiskerFlowAppSupport

final class MeetingCaptureTests: XCTestCase {
    func testEncryptedChunkRoundTripsAndRecoveryIgnoresPartialFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whiskerflow-meeting-tests-\(UUID().uuidString)")
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
            .appendingPathComponent("whiskerflow-meeting-tests-\(UUID().uuidString)")
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
            .appendingPathComponent("whiskerflow-meeting-tests-\(UUID().uuidString)")
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
            .appendingPathComponent("whiskerflow-meeting-tests-\(UUID().uuidString)")
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

    func testRecoverySkipsCorruptManifestAndKeepsValidSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whiskerflow-meeting-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = EncryptedMeetingChunkStore(
            rootURL: root,
            keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))
        )
        let validSessionID = UUID()
        _ = try store.beginSession(
            sessionID: validSessionID,
            meetingID: nil,
            expectedChunkCounts: [.mixed: 1]
        )

        let corruptSessionID = UUID()
        let corruptDirectory = root.appendingPathComponent(corruptSessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data().write(to: corruptDirectory.appendingPathComponent("manifest.json"))

        let recovered = try store.recoverSessions()
        XCTAssertEqual(recovered.map(\.sessionID), [validSessionID])
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

    func testAutomaticScheduleWindowDoesNotLetDensePastCalendarHideUpcomingCalls() {
        let nowMs: Int64 = 1_000_000_000

        let window = MeetingScheduleWindow.automaticCapture(
            nowMs: nowMs,
            lookaheadMs: 7 * 24 * 60 * 60 * 1_000
        )

        XCTAssertEqual(window.fromMs, nowMs - 30 * 60 * 1_000)
        XCTAssertEqual(window.toMs, nowMs + 7 * 24 * 60 * 60 * 1_000)
    }

    func testAutomaticScheduleWindowIncludesMeetingsStartedWithinLatePollRecoveryWindow() {
        let nowMs: Int64 = 1_000_000_000

        let window = MeetingScheduleWindow.automaticCapture(
            nowMs: nowMs,
            lookaheadMs: 7 * 24 * 60 * 60 * 1_000
        )

        let lookbackMs = nowMs - window.fromMs
        XCTAssertGreaterThanOrEqual(lookbackMs, 25 * 60 * 1_000)
        XCTAssertLessThan(lookbackMs, 31 * 60 * 1_000)
    }

    func testAutomaticCaptureIgnoresCalendarBlocksWithoutJoinURLs() {
        let task = AtlasCaptureScheduleIntent(
            eventID: "task",
            title: "Write a task brief",
            startMs: 1_000,
            endMs: 2_000,
            meetingURL: nil,
            location: nil,
            existingMeetingID: nil,
            overlapsPrevious: false
        )
        let call = AtlasCaptureScheduleIntent(
            eventID: "call",
            title: "Google Meet call",
            startMs: 2_000,
            endMs: 3_000,
            meetingURL: "https://meet.google.com/abc-defg-hij",
            location: nil,
            existingMeetingID: nil,
            overlapsPrevious: false
        )

    let candidates = MeetingCaptureSchedulePolicy.automaticCaptureIntents(from: [task, call])

    XCTAssertEqual(candidates.map(\.eventID), ["call"])
}

func testAutomaticCaptureOverlapIgnoresNonMeetingCalendarBlocks() {
    let task = AtlasCaptureScheduleIntent(
        eventID: "task",
        title: "Write a task brief",
        startMs: 1_000,
        endMs: 2_000,
        meetingURL: nil,
        location: nil,
        existingMeetingID: nil,
        overlapsPrevious: false
    )
    let call = AtlasCaptureScheduleIntent(
        eventID: "call",
        title: "Google Meet call",
        startMs: 1_500,
        endMs: 2_500,
        meetingURL: "https://meet.google.com/abc-defg-hij",
        location: nil,
        existingMeetingID: nil,
        overlapsPrevious: true
    )

    let candidates = MeetingCaptureSchedulePolicy.automaticCaptureIntents(from: [task, call])

    XCTAssertEqual(candidates.map(\.eventID), ["call"])
    XCTAssertFalse(candidates[0].overlapsPrevious)
}

    func testRecoveryOrderPrioritizesTheMostRecentMeeting() {
        let old = MeetingRecordingSessionManifest(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            meetingID: nil,
            createdAt: Date(timeIntervalSince1970: 1_000),
            expectedChunkCounts: [.mixed: 1],
            occurredAtMs: 1_000_000
        )
        let recent = MeetingRecordingSessionManifest(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            meetingID: nil,
            createdAt: Date(timeIntervalSince1970: 2_000),
            expectedChunkCounts: [.mixed: 1],
            occurredAtMs: 2_000_000
        )

        let ordered = MeetingRecordingSessionManifest.orderedForRecovery([old, recent])

        XCTAssertEqual(ordered.map(\.sessionID), [recent.sessionID, old.sessionID])
    }

    func testInterruptedAlignedSessionDoesNotInventSourceGap() {
        let sessionID = UUID()
        let chunks = MeetingAudioTrack.allCases.flatMap { track in
            (0..<2).map { sequence in
                MeetingRecordingChunkDescriptor(
                    track: track,
                    sequence: sequence,
                    startMs: Int64(sequence) * 10_000,
                    endMs: Int64(sequence + 1) * 10_000,
                    byteSize: 4,
                    checksum: "checksum-\(track.rawValue)-\(sequence)",
                    relativePath: "chunks/\(track.rawValue)-\(sequence).wfchunk"
                )
            }
        }
        let manifest = MeetingRecordingSessionManifest(
            sessionID: sessionID,
            meetingID: nil,
            expectedChunkCounts: [.microphone: 720, .system: 720, .mixed: 720],
            state: .recording,
            chunks: chunks
        )

        XCTAssertFalse(manifest.hasStructuralSourceGap)
    }

    func testRecoveryDetectsAChunkSequenceGap() {
        let chunks = [
            MeetingRecordingChunkDescriptor(
                track: .mixed,
                sequence: 0,
                startMs: 0,
                endMs: 10_000,
                byteSize: 4,
                checksum: "first",
                relativePath: "chunks/mixed-0.wfchunk"
            ),
            MeetingRecordingChunkDescriptor(
                track: .mixed,
                sequence: 2,
                startMs: 20_000,
                endMs: 30_000,
                byteSize: 4,
                checksum: "third",
                relativePath: "chunks/mixed-2.wfchunk"
            ),
        ]
        let manifest = MeetingRecordingSessionManifest(
            sessionID: UUID(),
            meetingID: nil,
            expectedChunkCounts: [.mixed: 720],
            state: .recording,
            chunks: chunks
        )

        XCTAssertTrue(manifest.hasStructuralSourceGap)
    }
}
