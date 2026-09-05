import XCTest
@testable import WhiskerFlowCore

final class TranscriptStoreTests: XCTestCase {
    func testFailedRecordsRemainRetryableUntilTheySucceed() throws {
        let failed = TranscriptRecord(
            text: "",
            audioFilePath: "/tmp/failed.wav",
            createdAt: Date(timeIntervalSince1970: 200),
            status: .failed(errorMessage: "Whisper exited 1")
        )
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = TranscriptStore(
            fileURL: fileURL,
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
