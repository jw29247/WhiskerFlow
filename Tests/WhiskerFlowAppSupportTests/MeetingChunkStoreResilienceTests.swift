import CryptoKit
import XCTest
@testable import WhiskerFlowAppSupport

final class MeetingChunkStoreResilienceTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whiskerflow-store-resilience-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeStore(_ provider: any MeetingChunkKeyProviding = FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256))) -> EncryptedMeetingChunkStore {
        EncryptedMeetingChunkStore(rootURL: root, keyProvider: provider)
    }

    private func chunksDirectory(_ sessionID: UUID) -> URL {
        root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("chunks", isDirectory: true)
    }

    func testTruncatedUnknownChunkIsQuarantinedWithoutHidingTheSession() throws {
        let store = makeStore()
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 2])
        let good = try store.writeChunk(sessionID: sessionID, track: .mixed, sequence: 0, startMs: 0, endMs: 10_000, plaintext: Data("good".utf8))
        // A power loss left a final file whose bytes do not match its name.
        let truncated = chunksDirectory(sessionID).appendingPathComponent("mixed-1-10000-20000-\(String(repeating: "a", count: 64)).wfchunk")
        try Data("trunc".utf8).write(to: truncated)

        let recovered = try store.recoverSessions()
        XCTAssertEqual(recovered.map(\.sessionID), [sessionID])
        XCTAssertEqual(recovered[0].chunks, [good])
        XCTAssertTrue(recovered[0].sourceGapDetected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: truncated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: truncated.appendingPathExtension("corrupt").path))
    }

    func testRecoveryDoesNotRehashKnownChunksAndVerifiesThemOnRead() throws {
        let store = makeStore()
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 1])
        let descriptor = try store.writeChunk(sessionID: sessionID, track: .mixed, sequence: 0, startMs: 0, endMs: 10_000, plaintext: Data("audio".utf8))
        // Same size, different bytes: only a full read can tell.
        let url = root.appendingPathComponent(sessionID.uuidString).appendingPathComponent(descriptor.relativePath)
        let flipped = Data(try Data(contentsOf: url).map { $0 ^ 0xFF })
        try flipped.write(to: url)

        let recovered = try store.recoverSessions()
        XCTAssertEqual(recovered.first?.chunks, [descriptor])
        XCTAssertThrowsError(try store.readEncryptedChunk(sessionID: sessionID, descriptor: descriptor)) { error in
            XCTAssertEqual(error as? MeetingChunkStoreError, .checksumMismatch)
        }
    }

    func testMissingPendingChunkIsDroppedWithGapInsteadOfBlockingDelivery() throws {
        let store = makeStore()
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 2])
        let first = try store.writeChunk(sessionID: sessionID, track: .mixed, sequence: 0, startMs: 0, endMs: 10_000, plaintext: Data("one".utf8))
        let second = try store.writeChunk(sessionID: sessionID, track: .mixed, sequence: 1, startMs: 10_000, endMs: 20_000, plaintext: Data("two".utf8))
        try FileManager.default.removeItem(at: root.appendingPathComponent(sessionID.uuidString).appendingPathComponent(second.relativePath))

        let recovered = try XCTUnwrap(try store.recoverSessions().first)
        XCTAssertEqual(recovered.chunks, [first])
        XCTAssertTrue(recovered.sourceGapDetected)
    }

    func testOrphanChunkWithRecordedSequenceIsNotAddedTwice() throws {
        let store = makeStore()
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 1])
        let recorded = try store.writeChunk(sessionID: sessionID, track: .mixed, sequence: 0, startMs: 0, endMs: 10_000, plaintext: Data("kept".utf8))

        // Simulate a chunk that was moved into place before its manifest write
        // failed, then retried under the same sequence by the writer.
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent("orphan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let other = EncryptedMeetingChunkStore(rootURL: otherRoot, keyProvider: FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256)))
        try other.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 1])
        let orphan = try other.writeChunk(sessionID: sessionID, track: .mixed, sequence: 0, startMs: 0, endMs: 10_000, plaintext: Data("orphan".utf8))
        try FileManager.default.copyItem(
            at: otherRoot.appendingPathComponent(sessionID.uuidString).appendingPathComponent(orphan.relativePath),
            to: root.appendingPathComponent(sessionID.uuidString).appendingPathComponent(orphan.relativePath)
        )

        let recovered = try XCTUnwrap(try store.recoverSessions().first)
        XCTAssertEqual(recovered.chunks, [recorded])
    }

    func testUploadReceiptsAreBatchedButDurableOnceEveryChunkIsUploaded() throws {
        let store = makeStore(FixedMeetingChunkKeyProvider(key: SymmetricKey(size: .bits256)))
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 3])
        let descriptors = try (0..<3).map { sequence in
            try store.writeChunk(sessionID: sessionID, track: .mixed, sequence: sequence, startMs: Int64(sequence) * 10_000, endMs: Int64(sequence + 1) * 10_000, plaintext: Data("chunk-\(sequence)".utf8))
        }
        try store.markUploaded(sessionID: sessionID, track: .mixed, sequence: descriptors[0].sequence)
        XCTAssertEqual(try store.loadManifest(sessionID: sessionID).pendingChunks.count, 2, "In-process reads see unsaved receipts")

        for descriptor in descriptors.dropFirst() {
            try store.markUploaded(sessionID: sessionID, track: .mixed, sequence: descriptor.sequence)
        }
        let manifestURL = root.appendingPathComponent(sessionID.uuidString).appendingPathComponent("manifest.json")
        let persisted = try JSONDecoder().decode(MeetingRecordingSessionManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertTrue(persisted.pendingChunks.isEmpty)
        XCTAssertEqual(persisted.state, .awaitingTranscription)
    }

    func testDeliveryFailuresHoldForManualRetryAndRetryReleasesThem() throws {
        let store = makeStore()
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 1])
        XCTAssertFalse(try store.recordDeliveryFailure(sessionID: sessionID, countsTowardLimit: false, maximumAttempts: 2))
        XCTAssertFalse(try store.recordDeliveryFailure(sessionID: sessionID, countsTowardLimit: true, maximumAttempts: 2))
        XCTAssertTrue(try store.recordDeliveryFailure(sessionID: sessionID, countsTowardLimit: true, maximumAttempts: 2))

        // The hold survives a relaunch (a fresh store reads the manifest).
        let relaunched = makeStore()
        XCTAssertEqual(try relaunched.recoverSessions().first?.awaitingManualRetry, true)
        let released = try XCTUnwrap(try relaunched.recoverSessions(releasingManualRetryHolds: true).first)
        XCTAssertFalse(released.awaitingManualRetry)
        XCTAssertEqual(released.deliveryFailureCount, 0)

        XCTAssertTrue(try relaunched.recordDeliveryFailure(sessionID: sessionID, countsTowardLimit: true, holdImmediately: true, maximumAttempts: 4))
    }

    func testSpeakerEvidenceStaysBoundedAndKeepsEveryRow() throws {
        let store = makeStore()
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 1])
        let saves = 700
        for index in 0..<saves {
            try store.saveSpeakerEvidence(sessionID: sessionID, evidence: [
                MeetingSpeakerEvidence(startMs: Int64(index) * 1_000, endMs: Int64(index) * 1_000 + 500, participantID: "p\(index % 3)", displayName: "Person \(index % 3)"),
            ])
        }
        let directory = root.appendingPathComponent(sessionID.uuidString).appendingPathComponent("speakers")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertLessThan(files.count, 200)
        let loaded = try store.loadSpeakerEvidence(sessionID: sessionID)
        XCTAssertEqual(Set(loaded.map(\.startMs)).count, saves)

        // One unreadable file must not discard the rest.
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("broken.enc"))
        XCTAssertEqual(Set(try store.loadSpeakerEvidence(sessionID: sessionID).map(\.startMs)).count, saves)
    }

    func testTransientKeychainFailureIsNotCachedForTheProcessLifetime() throws {
        let provider = ToggleKeyProvider()
        provider.fails = true
        let store = makeStore(provider)
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 1])
        XCTAssertThrowsError(try store.writeChunk(sessionID: sessionID, track: .mixed, sequence: 0, startMs: 0, endMs: 1_000, plaintext: Data("a".utf8)))
        XCTAssertThrowsError(try store.prepareEncryptionKey())

        provider.fails = false
        XCTAssertNoThrow(try store.prepareEncryptionKey())
        XCTAssertNoThrow(try store.writeChunk(sessionID: sessionID, track: .mixed, sequence: 0, startMs: 0, endMs: 1_000, plaintext: Data("a".utf8)))
    }

    func testFailedChunkWriteKeepsSamplesAndTheirTimeline() throws {
        let provider = ToggleKeyProvider()
        provider.fails = true
        let store = makeStore(provider)
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 1])
        let writer = MeetingPCMChunkWriter(store: store, sessionID: sessionID)
        let chunk = [Float](repeating: 0.1, count: MeetingPCMChunkWriter.chunkSampleCount)

        XCTAssertThrowsError(try writer.append(chunk, track: .mixed))
        provider.fails = false
        try store.prepareEncryptionKey()
        let written = try writer.append(chunk, track: .mixed)

        XCTAssertEqual(written.map(\.sequence), [0, 1])
        XCTAssertEqual(written.map(\.startMs), [0, 10_000])
        XCTAssertFalse(writer.sourceGapDetected)
    }

    func testSustainedWriteFailureDropsOldestChunkWithSkippedSequence() throws {
        let provider = ToggleKeyProvider()
        provider.fails = true
        let store = makeStore(provider)
        let sessionID = UUID()
        try store.beginSession(sessionID: sessionID, meetingID: nil, expectedChunkCounts: [.mixed: 1])
        let writer = MeetingPCMChunkWriter(store: store, sessionID: sessionID)
        let chunk = [Float](repeating: 0.1, count: MeetingPCMChunkWriter.chunkSampleCount)

        for _ in 0..<MeetingPCMChunkWriter.maximumBufferedChunks {
            _ = try? writer.append(chunk, track: .mixed)
        }
        XCTAssertTrue(writer.sourceGapDetected)

        provider.fails = false
        try store.prepareEncryptionKey()
        let written = try writer.append(chunk, track: .mixed)
        XCTAssertEqual(written.first?.sequence, 1, "The dropped chunk's sequence is skipped, not reused")
        XCTAssertEqual(written.first?.startMs, 10_000)
        XCTAssertEqual(written.count, MeetingPCMChunkWriter.maximumBufferedChunks)
    }

    func testRetryBackoffReportsEarliestCooldownOnlyWhenNothingIsReady() {
        var backoff = MeetingRetryBackoff()
        let first = UUID(), second = UUID()
        backoff.failed(first, now: 0)   // ready at 60
        backoff.failed(second, now: 0)
        backoff.failed(second, now: 0)  // ready at 300
        XCTAssertEqual(backoff.nextReadyTime(among: [first, second], now: 10), 60)
        XCTAssertNil(backoff.nextReadyTime(among: [first, second], now: 60))
        XCTAssertNil(backoff.nextReadyTime(among: [first, UUID()], now: 10), "A never-failed session is ready now")
    }

    func testManualStopSuppressesTheEventUntilItsWindowCloses() {
        var suppression = MeetingCaptureSuppression()
        suppression.suppress(eventID: "event", untilMs: 1_000)
        XCTAssertTrue(suppression.isSuppressed("event", nowMs: 999))
        XCTAssertTrue(suppression.isSuppressed("event", nowMs: 1_000))
        XCTAssertFalse(suppression.isSuppressed("event", nowMs: 1_001))
        XCTAssertFalse(suppression.isSuppressed("other", nowMs: 0))
        suppression.release(eventID: "event")
        XCTAssertFalse(suppression.isSuppressed("event", nowMs: 0))
        suppression.suppress(eventID: "event", untilMs: 1_000)
        suppression.prune(nowMs: 2_000)
        XCTAssertEqual(suppression, MeetingCaptureSuppression())
    }
}

private final class ToggleKeyProvider: MeetingChunkKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let key = SymmetricKey(size: .bits256)
    private var shouldFail = false

    var fails: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shouldFail }
        set { lock.lock(); shouldFail = newValue; lock.unlock() }
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        if fails { throw MeetingChunkStoreError.keychain(errSecInteractionNotAllowed) }
        return key
    }
}
