import XCTest
@testable import WhiskerFlowCore

final class TranscriptStoreTests: XCTestCase {
    func testPruneKeepsRecentTranscriptsAndDropsItemsOlderThanThirtyDays() throws {
        let recent = TranscriptRecord(
            text: "Recent note",
            audioFilePath: "/tmp/recent.wav",
            createdAt: Date(timeIntervalSince1970: 100),
            status: .transcribed
        )
        let expired = TranscriptRecord(
            text: "Old note",
            audioFilePath: "/tmp/old.wav",
            createdAt: Date(timeIntervalSince1970: 100 - (31 * 24 * 60 * 60)),
            status: .transcribed
        )
        let store = TranscriptStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
            now: { Date(timeIntervalSince1970: 100) }
        )

        try store.replaceAll([recent, expired])
        try store.pruneExpired()

        XCTAssertEqual(store.records.map(\.id), [recent.id])
    }

    func testFailedRecordsRemainRetryableUntilTheySucceed() throws {
        let failed = TranscriptRecord(
            text: "",
            audioFilePath: "/tmp/failed.wav",
            createdAt: Date(timeIntervalSince1970: 200),
            status: .failed(errorMessage: "Whisper exited 1")
        )
        let store = TranscriptStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString),
            now: { Date(timeIntervalSince1970: 200) }
        )

        try store.replaceAll([failed])

        XCTAssertEqual(store.retryQueue.map(\.id), [failed.id])

        try store.markTranscribed(id: failed.id, text: "Retried text")

        XCTAssertTrue(store.retryQueue.isEmpty)
        XCTAssertEqual(store.records.first?.text, "Retried text")
        XCTAssertEqual(store.records.first?.status, .transcribed)
    }
}
