import XCTest
@testable import WhiskerFlowCore

private final class RemovedPaths {
    var paths: [String] = []
}

private struct BackupFailure: Error {}

final class TranscriptStoreCleanupTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhiskerFlowTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("transcripts.json")
    }

    func testDeleteRemovesRecordAndItsAudioFile() throws {
        let removed = RemovedPaths()
        let store = TranscriptStore(fileURL: tempURL(), removeAudioFile: { removed.paths.append($0) })
        let record = TranscriptRecord(text: "hi", audioFilePath: "/tmp/keep.m4a", status: .transcribed)
        try store.replaceAll([record])

        try store.delete(id: record.id)

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(removed.paths, ["/tmp/keep.m4a"])
    }

    func testPruneRemovesExpiredAudioFiles() throws {
        let removed = RemovedPaths()
        let now = Date(timeIntervalSince1970: 100_000_000)
        let store = TranscriptStore(
            fileURL: tempURL(),
            now: { now },
            removeAudioFile: { removed.paths.append($0) }
        )
        let fresh = TranscriptRecord(text: "fresh", audioFilePath: "/tmp/fresh.m4a", createdAt: now, status: .transcribed)
        let stale = TranscriptRecord(
            text: "stale",
            audioFilePath: "/tmp/stale.m4a",
            createdAt: now.addingTimeInterval(-40 * 24 * 60 * 60),
            status: .transcribed
        )
        try store.replaceAll([fresh, stale])

        try store.pruneExpired()

        XCTAssertEqual(store.records.map(\.id), [fresh.id])
        XCTAssertEqual(removed.paths, ["/tmp/stale.m4a"])
    }

    func testPruneKeepsOnlyTheNewest25Sessions() throws {
        let now = Date(timeIntervalSince1970: 100_000_000)
        let removed = RemovedPaths()
        let store = TranscriptStore(
            fileURL: tempURL(),
            now: { now },
            retentionLimit: 25,
            removeAudioFile: { removed.paths.append($0) }
        )
        let records = (0..<26).map { index in
            TranscriptRecord(
                text: "session \(index)",
                audioFilePath: "/tmp/session-\(index).wav",
                createdAt: now.addingTimeInterval(TimeInterval(index)),
                status: .transcribed
            )
        }
        try store.replaceAll(records)
        try store.pruneExpired()

        XCTAssertEqual(store.records.count, 25)
        XCTAssertFalse(store.records.contains { $0.text == "session 0" })
        XCTAssertEqual(removed.paths, ["/tmp/session-0.wav"])
    }

    func testLoadRemovesOldOrphanWavsButKeepsRecentOrphanWavs() throws {
        let now = Date(timeIntervalSince1970: 100_000_000)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhiskerFlowRecordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldOrphan = directory.appendingPathComponent("old.wav")
        let recentOrphan = directory.appendingPathComponent("recent.wav")
        try Data("old".utf8).write(to: oldOrphan)
        try Data("recent".utf8).write(to: recentOrphan)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-31 * 24 * 60 * 60)],
            ofItemAtPath: oldOrphan.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 24 * 60 * 60)],
            ofItemAtPath: recentOrphan.path
        )

        let url = directory.appendingPathComponent("transcripts.json")
        let record = TranscriptRecord(
            text: "retained",
            audioFilePath: directory.appendingPathComponent("retained.wav").path,
            createdAt: now,
            status: .transcribed
        )
        let data = try JSONEncoder.whiskerFlow.encode([record])
        try data.write(to: url)

        let store = TranscriptStore(
            fileURL: url,
            now: { now },
            recordingsDirectory: directory
        )
        try store.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOrphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentOrphan.path))
        XCTAssertEqual(store.records.map(\.id), [record.id])
    }

    func testLoadSweepsOldOrphansWhenTranscriptIndexIsMissing() throws {
        let now = Date(timeIntervalSince1970: 100_000_000)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhiskerFlowMissingIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldOrphan = directory.appendingPathComponent("old.wav")
        try Data("old".utf8).write(to: oldOrphan)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-31 * 24 * 60 * 60)],
            ofItemAtPath: oldOrphan.path
        )

        let url = directory.appendingPathComponent("transcripts.json")
        let store = TranscriptStore(
            fileURL: url,
            now: { now },
            recordingsDirectory: directory
        )
        try store.load()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldOrphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTranscribingRecordsAreNotInRetryQueue() throws {
        let store = TranscriptStore(fileURL: tempURL())
        let inProgress = TranscriptRecord(text: "", audioFilePath: "/tmp/x.m4a", status: .transcribing)
        let failed = TranscriptRecord(text: "", audioFilePath: "/tmp/y.m4a", status: .failed(errorMessage: "boom"))
        try store.replaceAll([inProgress, failed])

        XCTAssertEqual(store.retryQueue.map(\.id), [failed.id])
    }

    func testCorruptFileIsBackedUpAndStoreStartsEmpty() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: url)

        let store = TranscriptStore(fileURL: url, now: { Date(timeIntervalSince1970: 42) })
        try store.load()

        XCTAssertTrue(store.records.isEmpty)
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt-42.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "corrupt file should be preserved")
        XCTAssertEqual(try Data(contentsOf: backup), Data("{ not json".utf8))

        let record = TranscriptRecord(text: "fresh", audioFilePath: "", status: .transcribed)
        try store.add(record)
        let reloaded = try JSONDecoder.whiskerFlow.decode([TranscriptRecord].self, from: Data(contentsOf: url))
        XCTAssertEqual(reloaded.map(\.id), [record.id])
    }

    func testCorruptFileFallsBackToCopyWhenMoveFails() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not json".utf8).write(to: url)

        let store = TranscriptStore(
            fileURL: url,
            now: { Date(timeIntervalSince1970: 42) },
            moveItem: { _, _ in throw BackupFailure() }
        )
        try store.load()

        XCTAssertTrue(store.records.isEmpty)
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt-42.json")
        XCTAssertEqual(try Data(contentsOf: backup), Data("{ not json".utf8))
        let rewritten = try JSONDecoder.whiskerFlow.decode([TranscriptRecord].self, from: Data(contentsOf: url))
        XCTAssertTrue(rewritten.isEmpty)
    }

    func testUnbackedUpCorruptFileThrowsAndBlocksFurtherWrites() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("{ not json".utf8)
        try original.write(to: url)

        let store = TranscriptStore(
            fileURL: url,
            now: { Date(timeIntervalSince1970: 42) },
            moveItem: { _, _ in throw BackupFailure() },
            copyItem: { _, _ in throw BackupFailure() }
        )

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TranscriptStoreError, .corruptFileUnrecoverable(path: url.path))
        }

        XCTAssertTrue(store.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)

        let record = TranscriptRecord(text: "fresh", audioFilePath: "", status: .transcribed)
        XCTAssertThrowsError(try store.add(record)) { error in
            XCTAssertEqual(error as? TranscriptStoreError, .corruptFileUnrecoverable(path: url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)

        // Replacing the whole list is no more entitled to destroy the only copy of
        // an unparsed history than appending to it is.
        XCTAssertThrowsError(try store.replaceAll([record])) { error in
            XCTAssertEqual(error as? TranscriptStoreError, .corruptFileUnrecoverable(path: url.path))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testBackupIsNotClaimedWhenAnEntryAlreadyOccupiesTheBackupPath() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("{ not json".utf8)
        try original.write(to: url)
        let backup = url.deletingPathExtension().appendingPathExtension("corrupt-42.json")
        let squatter = Data("an older, unrelated backup".utf8)
        try squatter.write(to: backup)

        // Move and copy both refuse an occupied destination; a `fileExists` probe at
        // that path would report success and clear the way to overwrite the original.
        let store = TranscriptStore(fileURL: url, now: { Date(timeIntervalSince1970: 42) })
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? TranscriptStoreError, .corruptFileUnrecoverable(path: url.path))
        }

        XCTAssertEqual(try Data(contentsOf: url), original, "the corrupt bytes must survive")
        XCTAssertEqual(try Data(contentsOf: backup), squatter, "the occupant must not be replaced")
    }
}
