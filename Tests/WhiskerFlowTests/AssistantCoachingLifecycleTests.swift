import Foundation
import XCTest
@testable import WhiskerFlow

private actor CoachingLifecycleTransport: AssistantAtlasTransport {
    private var failDeletion: Bool
    private let wrongReceipt: Bool
    private let beforeDeletion: (@Sendable () async -> Void)?
    init(failDeletion: Bool = true, wrongReceipt: Bool = false,
         beforeDeletion: (@Sendable () async -> Void)? = nil) {
        self.failDeletion = failDeletion; self.wrongReceipt = wrongReceipt
        self.beforeDeletion = beforeDeletion
    }
    private var deletionPayloads: [Data] = []
    func call(operation: String, arguments: Data) async throws -> Data {
        let row: [String: Any]
        switch operation {
        case "requestCoach": row = ["contractVersion": 1, "jobReference": "owned-coach", "status": "queued"]
        case "getResult": row = ["contractVersion": 1, "status": "ready", "result": [
            "kind": "coach", "phase": "premeeting", "title": "Private plan",
            "suggestions": [["text": "Confirm the objective", "evidence": []]], "incomplete": false
        ]]
        case "deleteCoach":
            deletionPayloads.append(arguments)
            await beforeDeletion?()
            if failDeletion { failDeletion = false; throw AssistantError.message("Offline") }
            let args = try JSONSerialization.jsonObject(with: arguments) as! [String: Any]
            row = ["contractVersion": 1, "jobReference": wrongReceipt ? "another-job" : args["jobReference"]!, "deleted": true]
        default: throw AssistantError.message("Unexpected operation")
        }
        return try JSONSerialization.data(withJSONObject: row)
    }
    func deletions() -> [Data] { deletionPayloads }
}

final class AssistantCoachingLifecycleTests: XCTestCase {
    @MainActor func testCompletedCoachRetainsDurableHandleBeforePendingJobIsCleared() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("assistant.json")
        let controller = AssistantController(fileURL: url)
        let transport = CoachingLifecycleTransport()
        controller.requestTransport = { transport }
        controller.setCloudEnabled(true)
        await controller.requestCoach(phase: "premeeting", goal: "Agree a decision")
        XCTAssertNil(controller.saved.pendingJob)
        XCTAssertNotNil(controller.coachResult)
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let records = document["coachRecords"] as? [[String: Any]]
        XCTAssertEqual(records?.first?["jobReference"] as? String, "owned-coach",
                       "Completed results must retain the reference required for reopen and owner deletion")
    }
    @MainActor func testLocalTemplateSaveReopenAndDeleteNeverUsesAtlas() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("assistant.json")
        let controller = AssistantController(fileURL: url)
        await controller.requestCoach(phase: "premeeting", goal: "Agree the plan")
        let id = try XCTUnwrap(controller.currentCoachRecord?.id)
        XCTAssertFalse(controller.currentCoachRecord?.isSaved ?? true)
        controller.saveCurrentCoach()
        XCTAssertTrue(controller.currentCoachRecord?.isSaved == true)
        let restarted = AssistantController(fileURL: url)
        restarted.openCoach(id)
        XCTAssertEqual(restarted.coachResult, controller.coachResult)
        XCTAssertEqual(restarted.message, "Opened saved coaching from this Mac.")
        await restarted.deleteCoach(id)
        XCTAssertTrue(restarted.visibleCoachRecords.isEmpty)
        XCTAssertNil(restarted.coachResult)
        XCTAssertTrue(AssistantController(fileURL: url).visibleCoachRecords.isEmpty)
    }

    @MainActor func testRemoteDeletionFailureSurvivesRestartAndRetriesSameRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("assistant.json")
        let controller = AssistantController(fileURL: url)
        let transport = CoachingLifecycleTransport()
        controller.accountIdentityProvider = { "owner-one" }
        controller.synchronizeAccount()
        controller.requestTransport = { transport }
        controller.setCloudEnabled(true)
        await controller.requestCoach(phase: "premeeting", goal: "Private goal")
        let id = try XCTUnwrap(controller.currentCoachRecord?.id)
        controller.saveCurrentCoach()
        await controller.deleteCoach(id)
        XCTAssertNil(controller.coachResult)
        XCTAssertNil(controller.visibleCoachRecords.first?.result)
        XCTAssertNotNil(controller.visibleCoachRecords.first?.deletionRequestID)
        XCTAssertTrue(controller.message?.contains("pending") == true)
        let restarted = AssistantController(fileURL: url)
        restarted.accountIdentityProvider = { "owner-one" }
        restarted.requestTransport = { transport }
        restarted.setCloudEnabled(false) // Owner deletion must not require enabling inference.
        await restarted.deleteCoach(id)
        XCTAssertTrue(restarted.visibleCoachRecords.isEmpty)
        XCTAssertEqual(restarted.message, "Coaching deleted from Atlas and this Mac.")
        let requests = await transport.deletions()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: requests[0]) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: requests[1]) as? NSDictionary)
    }

    @MainActor func testAnotherConnectionCannotViewOrDeleteSavedCoaching() async throws {
        let controller = AssistantController()
        var identity = "owner-one"
        controller.accountIdentityProvider = { identity }
        controller.synchronizeAccount()
        let transport = CoachingLifecycleTransport()
        controller.requestTransport = { transport }
        controller.setCloudEnabled(true)
        await controller.requestCoach(phase: "premeeting", goal: "Private goal")
        let id = try XCTUnwrap(controller.currentCoachRecord?.id)
        controller.saveCurrentCoach()
        identity = "owner-two"
        XCTAssertNil(controller.coachResult, "Presentation must hide immediately, before a network request")
        XCTAssertTrue(controller.visibleCoachRecords.isEmpty)
        await controller.deleteCoach(id)
        let requests = await transport.deletions()
        XCTAssertTrue(requests.isEmpty)
        identity = "owner-one"
        controller.synchronizeAccount()
        controller.openCoach(id)
        XCTAssertNotNil(controller.coachResult)
    }

    @MainActor func testWrongDeletionReceiptRemainsPending() async throws {
        let controller = AssistantController()
        let transport = CoachingLifecycleTransport(failDeletion: false, wrongReceipt: true)
        controller.requestTransport = { transport }; controller.setCloudEnabled(true)
        await controller.requestCoach(phase: "premeeting", goal: "Goal")
        await controller.deleteCoach(try XCTUnwrap(controller.currentCoachRecord?.id))
        XCTAssertNotNil(controller.visibleCoachRecords.first?.deletionRequestID)
        XCTAssertTrue(controller.message?.contains("pending") == true)
    }

    @MainActor func testConnectionSwitchDiscardsLateDeletionAcknowledgement() async throws {
        let controller = AssistantController()
        var identity = "owner-one"
        controller.accountIdentityProvider = { identity }; controller.synchronizeAccount()
        let started = expectation(description: "delete started")
        let latch = CoachingDeletionLatch()
        let transport = CoachingLifecycleTransport(failDeletion: false) {
            started.fulfill()
            await latch.wait()
        }
        controller.requestTransport = { transport }; controller.setCloudEnabled(true)
        await controller.requestCoach(phase: "premeeting", goal: "Private")
        let id = try XCTUnwrap(controller.currentCoachRecord?.id)
        let deletion = Task { await controller.deleteCoach(id) }
        await fulfillment(of: [started], timeout: 2)
        identity = "owner-two"
        await latch.open()
        await deletion.value
        XCTAssertTrue(controller.visibleCoachRecords.isEmpty)
        XCTAssertNil(controller.coachResult)
        identity = "owner-one"; controller.synchronizeAccount()
        XCTAssertNotNil(controller.visibleCoachRecords.first?.deletionRequestID,
                        "The original owner must reconcile the ignored acknowledgement using the same request")
    }

    @MainActor func testFailedLocalWriteDoesNotClaimSaveOrSendDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("assistant.json")
        let controller = AssistantController(fileURL: url)
        let transport = CoachingLifecycleTransport()
        controller.requestTransport = { transport }; controller.setCloudEnabled(true)
        await controller.requestCoach(phase: "premeeting", goal: "Goal")
        let id = try XCTUnwrap(controller.currentCoachRecord?.id)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        controller.saveCurrentCoach()
        XCTAssertFalse(controller.currentCoachRecord?.isSaved ?? true)
        await controller.deleteCoach(id)
        XCTAssertNotNil(controller.coachResult)
        let requests = await transport.deletions()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(controller.message?.contains("Could not save locally") == true)
    }

    @MainActor func testOldAssistantFileWithoutCoachingFieldMigrates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("assistant.json")
        let encoded = try JSONEncoder().encode(AssistantController.SavedState())
        var original = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        original.removeValue(forKey: "coachRecords")
        try JSONSerialization.data(withJSONObject: original).write(to: url)
        let controller = AssistantController(fileURL: url)
        await controller.requestCoach(phase: "premeeting", goal: "Local")
        controller.saveCurrentCoach()
        XCTAssertTrue(controller.currentCoachRecord?.isSaved == true)
    }

    @MainActor func testDeleteLocalRecapPreservesBookmarksAndFinalizedMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MeetingAssistantController(rootURL: root)
        let session = UUID()
        controller.begin(sessionID: session, title: "Call")
        let bookmark = try controller.addBookmark(label: "Decision")
        controller.end(sessionID: session)
        await controller.finalize(sessionID: session, meetingReference: "owned-meeting", durationMilliseconds: 1_000)
        XCTAssertNotNil(controller.localReview)
        XCTAssertTrue(controller.deleteLocalReview())
        let restarted = MeetingAssistantController(rootURL: root)
        XCTAssertNil(restarted.localReview)
        XCTAssertEqual(restarted.bookmarks.map(\.id), [bookmark.id])
        XCTAssertEqual(restarted.latestFinalizedMeetingReference, "owned-meeting")
    }

    @MainActor func testForgetPendingDeletionFreesCapacityWithoutCloudRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("assistant.json")
        var state = AssistantController.SavedState()
        state.accountIdentity = "owner"
        state.coachRecords = (0..<100).map { index in
            SavedAssistantCoaching(accountIdentity: "owner", jobReference: "expired-job-\(index)",
                                   result: nil, deletionRequestID: UUID())
        }
        try JSONEncoder().encode(state).write(to: url)
        let controller = AssistantController(fileURL: url)
        controller.accountIdentityProvider = { "owner" }
        let transport = CoachingLifecycleTransport(); controller.requestTransport = { transport }
        await controller.requestCoach(phase: "premeeting", goal: "New local plan")
        XCTAssertNil(controller.coachResult)
        let id = try XCTUnwrap(controller.visibleCoachRecords.first?.id)
        XCTAssertTrue(controller.forgetPendingCoachDeletion(id))
        XCTAssertTrue(controller.message?.contains("not confirmed") == true)
        XCTAssertEqual(AssistantController(fileURL: url).saved.coachRecords?.count, 99)
        await controller.requestCoach(phase: "premeeting", goal: "New local plan")
        XCTAssertNotNil(controller.coachResult)
        let requests = await transport.deletions(); XCTAssertTrue(requests.isEmpty)
    }

    @MainActor func testForgetRejectsForeignRecordsAndFailedPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("assistant.json")
        let record = SavedAssistantCoaching(accountIdentity: "owner", jobReference: "expired",
                                           result: nil, deletionRequestID: UUID())
        var state = AssistantController.SavedState(); state.accountIdentity = "owner"; state.coachRecords = [record]
        try JSONEncoder().encode(state).write(to: url)
        let controller = AssistantController(fileURL: url)
        var identity = "other"; controller.accountIdentityProvider = { identity }
        XCTAssertFalse(controller.forgetPendingCoachDeletion(record.id))
        XCTAssertEqual(controller.saved.coachRecords?.count, 1)
        identity = "owner"; controller.synchronizeAccount()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertFalse(controller.forgetPendingCoachDeletion(record.id))
        XCTAssertEqual(controller.saved.coachRecords?.count, 1)
    }

    @MainActor func testLocalRecapOwnerIsBoundAtCaptureStartAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MeetingAssistantController(rootURL: root)
        var identity = "owner-one"; controller.accountIdentityProvider = { identity }
        let session = UUID(); controller.begin(sessionID: session, title: "Private")
        let bookmark = try controller.addBookmark(label: "Keep")
        identity = "owner-two"
        controller.end(sessionID: session)
        await controller.finalize(sessionID: session, meetingReference: "original-meeting", durationMilliseconds: 1_000)
        XCTAssertNil(controller.localReview)
        XCTAssertFalse(controller.deleteLocalReview())
        let restarted = MeetingAssistantController(rootURL: root)
        restarted.accountIdentityProvider = { identity }
        XCTAssertNil(restarted.localReview)
        identity = "owner-one"
        XCTAssertNotNil(restarted.localReview)
        XCTAssertTrue(restarted.deleteLocalReview())
        XCTAssertEqual(restarted.bookmarks.map(\.id), [bookmark.id])
        XCTAssertEqual(restarted.latestFinalizedMeetingReference, "original-meeting")
    }

    @MainActor func testLegacyUnownedRecapIsNotAttributedToNewConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = MeetingAssistantController(rootURL: root)
        let session = UUID(); controller.begin(sessionID: session, title: "Legacy"); controller.end(sessionID: session)
        let url = root.appendingPathComponent("private-meeting-assistant.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var sessions = document["sessions"] as! [[String: Any]]
        sessions[0].removeValue(forKey: "coachAccountIdentity"); document["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        let restarted = MeetingAssistantController(rootURL: root)
        restarted.accountIdentityProvider = { "new-owner" }
        XCTAssertNil(restarted.localReview)
        XCTAssertFalse(restarted.deleteLocalReview())
        restarted.accountIdentityProvider = { nil }
        XCTAssertNotNil(restarted.localReview)
    }

}

private actor CoachingDeletionLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}
