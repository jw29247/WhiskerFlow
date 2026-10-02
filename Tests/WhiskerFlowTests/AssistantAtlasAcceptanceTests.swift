import Foundation
import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

/// Explicitly opt-in: exercises the production URLSession client against a
/// disposable real Convex backend. The fixture provider remains synthetic.
final class AssistantAtlasAcceptanceTests: XCTestCase {
    struct Fixture: Decodable {
        let baseURL: URL
        let fixture: Bool
        let tokenFile: String
        let meetingId: String
        let clientReference: String
        let expectedRewrite: String
    }
    @MainActor
    func testNativeDraftVocabularyRewriteBookmarkAndCoachAgainstLocalAtlas() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHISKERFLOW_ASSISTANT_ACCEPTANCE_FILE"] else {
            throw XCTSkip("Requires an explicitly provisioned disposable local Atlas fixture")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard fixture.fixture, fixture.baseURL.scheme == "http", fixture.baseURL.host == "127.0.0.1" else {
            XCTFail("Acceptance must never target a production backend"); return
        }
        let token = try String(contentsOfFile: fixture.tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let transport = AssistantAtlasClient(baseURL: fixture.baseURL, token: token)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = AssistantController(fileURL: root.appendingPathComponent("assistant.json"))
        controller.requestTransport = { transport }
        await controller.refreshClients()
        XCTAssertTrue(controller.saved.clients.contains { $0.reference == fixture.clientReference }, controller.message ?? "Missing fixture client")
        controller.selectClient(fixture.clientReference)
        await controller.refreshSelectedVocabulary()
        XCTAssertFalse(controller.vocabulary.rules.isEmpty, controller.message ?? "Missing vocabulary")
        controller.selectClient(nil)

        for kind in AssistantRecordKind.allCases {
            let id = try XCTUnwrap(controller.saveLocalDraft("Synthetic native \(kind.rawValue) capture", kind: kind))
            await controller.sendDraft(id)
            let reference = try XCTUnwrap(controller.saved.drafts.first(where: { $0.id == id })?.atlasReference, controller.message ?? "Missing acknowledged draft")
            let duplicate = try await controller.call("captureDraft", ["requestId": id.uuidString, "kind": kind.rawValue,
                                                                        "title": "Synthetic native \(kind.rawValue) capture", "text": "Synthetic native \(kind.rawValue) capture"])
            XCTAssertEqual(duplicate["draftReference"] as? String, reference)
            let stored = try await controller.call("getDraft", ["draftReference": reference])
            XCTAssertEqual(stored["text"] as? String, "Synthetic native \(kind.rawValue) capture")
            _ = try await controller.call("discardDraft", ["requestId": UUID().uuidString, "draftReference": reference])
        }
        controller.setCloudEnabled(true)
        controller.rewriteInput = "Synthetic input for a native rewrite."
        await controller.rewrite(operation: "shorten")
        XCTAssertEqual(controller.rewritePreview, fixture.expectedRewrite, controller.message ?? "Rewrite not ready")
        XCTAssertNil(controller.saved.pendingJob)
        XCTAssertNil(controller.selection, "A transport test has no permission to replace an external field")

        var now = Date()
        let meeting = MeetingAssistantController(rootURL: root.appendingPathComponent("meeting"), now: { now })
        let session = UUID()
        meeting.begin(sessionID: session, title: "Synthetic local acceptance")
        now = now.addingTimeInterval(1)
        let bookmark = try meeting.addBookmark(label: "Synthetic decision")
        meeting.end(sessionID: session)
        meeting.bookmarkSync = { request in
            let row = try await controller.call("addBookmark", ["requestId": request.requestID.uuidString,
                "meetingReference": request.meetingReference, "offsetMs": request.elapsedMilliseconds, "label": request.label ?? ""])
            return try XCTUnwrap(row["bookmarkReference"] as? String)
        }
        await meeting.finalize(sessionID: session, meetingReference: fixture.meetingId, durationMilliseconds: 5_000)
        XCTAssertEqual(meeting.bookmarks.first(where: { $0.id == bookmark.id })?.syncState, .synced)
        let restarted = MeetingAssistantController(rootURL: root.appendingPathComponent("meeting"))
        XCTAssertEqual(restarted.bookmarks.first?.atlasReference, meeting.bookmarks.first?.atlasReference)
        await controller.requestCoach(phase: "postmeeting", goal: "Agree the next step", meetingReference: fixture.meetingId)
        let review = try XCTUnwrap(controller.coachResult, controller.message ?? "No coaching result")
        XCTAssertEqual(review.phase, "postmeeting")
        XCTAssertEqual(review.suggestions.first?.evidence.first?.quote, "Agree the next step.")
        XCTAssertEqual(review.suggestions.first?.evidence.first?.startMs, 1_000)
        XCTAssertFalse(review.incomplete)
    }
}
