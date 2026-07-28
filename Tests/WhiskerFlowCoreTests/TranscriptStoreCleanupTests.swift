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

        try store.replaceAll([record])
        let reloaded = try JSONDecoder.whiskerFlow.decode([TranscriptRecord].self, from: Data(contentsOf: url))
        XCTAssertEqual(reloaded.map(\.id), [record.id])
    }
}
