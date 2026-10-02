import XCTest
@testable import WhiskerFlowAppSupport

final class MeetingSpeakerEvidenceTests: XCTestCase {
    private func row(_ start: Int64, _ end: Int64, _ id: String = "a") -> MeetingSpeakerEvidence {
        .init(startMs: start, endMs: end, participantID: id, displayName: "Person " + id)
    }
    func testRequiresSustainedUniqueActivity() {
        XCTAssertEqual(MeetingSpeakerEvidenceMatcher.identity(startMs: 0, endMs: 1000, evidence: [row(0, 800)])?.displayName, "Person a")
        XCTAssertNil(MeetingSpeakerEvidenceMatcher.identity(startMs: 0, endMs: 1000, evidence: [row(0, 799)]))
        XCTAssertNil(MeetingSpeakerEvidenceMatcher.identity(startMs: 0, endMs: 1000, evidence: [row(0, 1000), row(500, 501, "b")]))
    }
    func testDuplicateSamplesDoNotInflateCoverageAndStaleSamplesDoNotMatch() {
        XCTAssertNil(MeetingSpeakerEvidenceMatcher.identity(startMs: 0, endMs: 1000, evidence: [row(0, 250), row(0, 250), row(0, 250), row(0, 250)]))
        XCTAssertNil(MeetingSpeakerEvidenceMatcher.identity(startMs: 1000, endMs: 2000, evidence: [row(0, 1000)]))
    }
    func testBufferCoalescesContiguousRowsAndFlushesInBatches() {
        var buffer = MeetingSpeakerEvidenceBuffer()
        // One timeline row per ~1.25 s probe cycle for 10 s of one speaker, then another.
        for cycle in 0..<8 { buffer.append([row(Int64(cycle) * 1250, Int64(cycle + 1) * 1250)], atMs: Int64(cycle + 1) * 1250) }
        buffer.append([row(10_000, 11_000, "b")], atMs: 11_000)
        XCTAssertEqual(buffer.pendingCount, 2)
        XCTAssertTrue(buffer.drain(atMs: 11_000).isEmpty, "Not due before the flush interval")
        let rows = buffer.drain(atMs: 1_250 + MeetingSpeakerEvidenceBuffer.flushIntervalMs)
        XCTAssertEqual(rows, [row(0, 10_000), row(10_000, 11_000, "b")])
        XCTAssertTrue(buffer.isEmpty)
        // Coalescing is lossless for the matcher.
        XCTAssertEqual(MeetingSpeakerEvidenceMatcher.identity(startMs: 1_000, endMs: 9_000, evidence: rows)?.displayName, "Person a")
    }
    func testBufferKeepsGapsNamesAndForcedFlush() {
        var buffer = MeetingSpeakerEvidenceBuffer()
        buffer.append([row(0, 1000), row(3000, 4000)], atMs: 4000)
        buffer.append([.init(startMs: 4000, endMs: 5000, participantID: "a", displayName: "Renamed")], atMs: 5000)
        XCTAssertEqual(buffer.pendingCount, 3, "A gap or changed name is never merged")
        XCTAssertEqual(buffer.drain(atMs: 5000, force: true).count, 3)
        XCTAssertTrue(buffer.drain(atMs: 5000, force: true).isEmpty)
    }
}
