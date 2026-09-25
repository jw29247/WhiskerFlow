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
    func testNativeInboxEncryptsAndRejectsUnarmedStaleAndCrossSessionData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try MeetingBrowserInbox.begin(sessionID: UUID(), startMs: MeetingBrowserInbox.nowMs, root: root)
        func bytes(_ time: Int64) -> Data { Data("{\"meetingCode\":\"abc-defg-hij\",\"samples\":[{\"atMs\":\(time),\"participantID\":\"fixture\",\"displayName\":\"Private Fixture\"}]}".utf8) }
        XCTAssertTrue(try MeetingBrowserInbox.accept(bytes(MeetingBrowserInbox.nowMs), root: root))
        let encrypted = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "incoming" }
        XCTAssertEqual(encrypted.count, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: XCTUnwrap(encrypted.first)), as: UTF8.self).contains("Private Fixture"))
        XCTAssertEqual(try MeetingBrowserInbox.drain(config, root: root).first?.samples.first?.displayName, "Private Fixture")
        XCTAssertFalse(try MeetingBrowserInbox.accept(bytes(Int64.min), root: root))
        XCTAssertFalse(try MeetingBrowserInbox.accept(bytes(MeetingBrowserInbox.nowMs - 11000), root: root))
        XCTAssertTrue(try MeetingBrowserInbox.accept(bytes(MeetingBrowserInbox.nowMs), root: root))
        let next = try MeetingBrowserInbox.begin(sessionID: UUID(), startMs: MeetingBrowserInbox.nowMs, root: root)
        XCTAssertTrue(try MeetingBrowserInbox.drain(next, root: root).isEmpty)
        MeetingBrowserInbox.end(next, root: root)
        XCTAssertThrowsError(try MeetingBrowserInbox.accept(bytes(MeetingBrowserInbox.nowMs), root: root))
    }
}
