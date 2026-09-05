import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

private actor AssistantFixtureTransport: AssistantAtlasTransport {
    var calls: [(String, Data)] = []
    var failFirst = false
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func call(operation: String, arguments: Data) async throws -> Data {
        calls.append((operation, arguments))
        if failFirst { failFirst = false; throw AssistantError.message("Offline") }
        let value: [String: Any]
        switch operation {
        case "captureDraft": value = ["contractVersion": 1, "draftReference": "draft_fixture", "status": "draft", "version": 1]
        case "rewrite": value = ["contractVersion": 1, "jobReference": "job_fixture", "status": "queued"]
        case "getResult": value = ["contractVersion": 1, "status": "ready", "result": ["kind": "rewrite", "text": "Please send the report."]]
        default: value = ["contractVersion": 1]
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func recordedCalls() -> [(String, Data)] { calls }
}

final class AssistantControllerTests: XCTestCase {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("assistant.json") }

    @MainActor func testDraftSurvivesRestartAndAmbiguousRetryUsesSamePayload() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = AssistantController(fileURL: url)
        let id = try XCTUnwrap(controller.saveLocalDraft("Review the Q4 proposal", kind: .taskDraft))
        let transport = AssistantFixtureTransport(failFirst: true)
        controller.requestTransport = { transport }
        await controller.sendDraft(id)
        XCTAssertNil(controller.saved.drafts.first?.atlasReference)
        let restarted = AssistantController(fileURL: url)
        restarted.requestTransport = { transport }
        await restarted.sendDraft(id)
        XCTAssertEqual(restarted.saved.drafts.first?.atlasReference, "draft_fixture")
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        let first = try JSONSerialization.jsonObject(with: calls[0].1) as? NSDictionary
        let second = try JSONSerialization.jsonObject(with: calls[1].1) as? NSDictionary
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?["requestId"] as? String, id.uuidString)
        XCTAssertEqual(first?["kind"] as? String, "taskDraft")
    }

    @MainActor func testCloudIsExplicitAndPendingJobResumesAfterRestart() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let transport = AssistantFixtureTransport(failFirst: true)
        let controller = AssistantController(fileURL: url)
        controller.requestTransport = { transport }
        controller.rewriteInput = "Please could you send the report."
        await controller.rewrite(operation: "shorten")
        let blockedCalls = await transport.recordedCalls()
        XCTAssertTrue(blockedCalls.isEmpty)
        controller.setCloudEnabled(true)
        await controller.rewrite(operation: "shorten")
        XCTAssertNotNil(controller.saved.pendingJob)
        let restarted = AssistantController(fileURL: url)
        restarted.requestTransport = { transport }
        await restarted.resumeJob()
        XCTAssertEqual(restarted.rewritePreview, "Please send the report.")
        XCTAssertEqual(restarted.rewriteInput, "Please could you send the report.")
        XCTAssertNil(restarted.selection, "A restored job can only offer Copy, not replace a different field")
        XCTAssertNil(restarted.saved.pendingJob)
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.map(\.0), ["rewrite", "rewrite", "getResult"])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: calls[0].1) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: calls[1].1) as? NSDictionary)
    }

    @MainActor func testConnectionChangePreventsSendingOtherAccountsDraft() async throws {
        let controller = AssistantController()
        var account = "account-one"
        controller.accountIdentityProvider = { account }
        controller.synchronizeAccount()
        let id = try XCTUnwrap(controller.saveLocalDraft("Private client note", kind: .note))
        let transport = AssistantFixtureTransport()
        controller.requestTransport = { transport }
        controller.setCloudEnabled(true)
        controller.selectClient("shared-client")
        controller.addClientTerm(find: "private-name", replacement: "Account One")
        XCTAssertFalse(controller.vocabulary.rules.isEmpty)
        account = "account-two"
        await controller.sendDraft(id)
        let calls = await transport.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(controller.saved.cloudEnabled)
        controller.selectClient("shared-client")
        XCTAssertTrue(controller.vocabulary.rules.isEmpty)
        XCTAssertTrue(controller.saved.clientUpdatedAt?.isEmpty ?? true)
        XCTAssertEqual(controller.saved.drafts.first?.accountIdentity, "account-one")
        XCTAssertNil(controller.saved.drafts.first?.atlasReference)
    }

    @MainActor func testPendingRewriteNeverResumesWithDifferentConnection() async throws {
        let controller = AssistantController()
        var account = "first-account"
        controller.accountIdentityProvider = { account }
        controller.synchronizeAccount()
        controller.setCloudEnabled(true)
        let transport = AssistantFixtureTransport(failFirst: true)
        controller.requestTransport = { transport }
        controller.rewriteInput = "Confidential first-account words"
        await controller.rewrite(operation: "shorten")
        XCTAssertNotNil(controller.saved.pendingJob)
        account = "second-account"
        await controller.resumeJob()
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.count, 1, "Only the original failed attempt may reach transport")
        XCTAssertNil(controller.saved.pendingJob)
        XCTAssertFalse(controller.saved.cloudEnabled)
    }

    @MainActor func testAccountSwitchFailsClosedIfStorageBecomesUnavailable() async throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = AssistantController(fileURL: url)
        var account = "first-account"
        controller.accountIdentityProvider = { account }
        controller.synchronizeAccount(); controller.setCloudEnabled(true)
        let transport = AssistantFixtureTransport(failFirst: true)
        controller.requestTransport = { transport }
        controller.rewriteInput = "Private first-account input"
        await controller.rewrite(operation: "shorten")
        XCTAssertNotNil(controller.saved.pendingJob)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        account = "second-account"
        await controller.resumeJob()
        let calls = await transport.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(controller.saved.accountIdentity, "first-account")
        XCTAssertFalse(controller.synchronizeAccount())
    }

    @MainActor func testDraftEditingStopsAfterFirstSubmissionAttempt() async throws {
        let controller = AssistantController()
        let id = try XCTUnwrap(controller.saveLocalDraft("Original draft", kind: .note))
        XCTAssertTrue(controller.editDraft(id, title: "Reviewed title", text: "Reviewed body"))
        let transport = AssistantFixtureTransport(failFirst: true)
        controller.requestTransport = { transport }
        await controller.sendDraft(id)
        XCTAssertFalse(controller.editDraft(id, title: "Changed title", text: "Changed body"))
        await controller.sendDraft(id)
        let calls = await transport.recordedCalls()
        XCTAssertEqual(try JSONSerialization.jsonObject(with: calls[0].1) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: calls[1].1) as? NSDictionary)
        XCTAssertEqual(controller.saved.drafts.first?.text, "Reviewed body")
    }

    @MainActor func testClientTermsStayInsideTheirSelectedProfile() {
        let controller = AssistantController()
        controller.selectClient("first-client")
        controller.addClientTerm(find: "Mark", replacement: "Marc")
        XCTAssertEqual(controller.vocabulary.apply(to: "Ask Mark"), "Ask Marc")
        controller.selectClient("second-client")
        XCTAssertEqual(controller.vocabulary.apply(to: "Ask Mark"), "Ask Mark")
        controller.selectClient("first-client")
        let personal = Vocabulary(rules: [.init(find: "Mark", replaceWith: "Marco")])
        XCTAssertEqual(Vocabulary.effective(shared: controller.vocabulary, personal: personal).apply(to: "Ask Mark"), "Ask Marco")
        controller.selectClient(nil)
        XCTAssertTrue(controller.vocabulary.rules.isEmpty)
    }

    @MainActor func testLocalPreparationMakesNoNetworkRequest() async {
        let controller = AssistantController()
        let transport = AssistantFixtureTransport()
        controller.requestTransport = { transport }
        await controller.requestCoach(phase: "premeeting", goal: "Agree a launch date", agenda: "Scope, risks, owners")
        XCTAssertEqual(controller.coachResult?.phase, "premeeting")
        XCTAssertTrue(controller.coachResult?.suggestions.first?.text.contains("Agree a launch date") == true)
        let calls = await transport.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor func testUnicodeStorageCapRejectsSaveBeforeCorruptingRestart() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let controller = AssistantController(fileURL: url)
        let content = String(repeating: "界", count: 8_000)
        var count = 0
        for _ in 0..<500 {
            if controller.saveLocalDraft(content, kind: .note) == nil { break }
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, 500)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 8_388_608)
        let restarted = AssistantController(fileURL: url)
        XCTAssertEqual(restarted.saved.drafts.count, count)
        XCTAssertNil(restarted.message)
    }

    @MainActor func testCorruptFileIsPreservedAndCannotReportDraftSaved() throws {
        let url = location(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{broken".utf8); try corrupt.write(to: url)
        let controller = AssistantController(fileURL: url)
        XCTAssertNil(controller.saveLocalDraft("Don't lose this", kind: .note))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertNotNil(controller.message)
    }

    func testProfilesKeepLiteralVerbatimAndPersonalVocabularyWins() {
        let raw = "um send it to Mark, sorry, Marc."
        let vocabulary = Vocabulary(rules: [.init(find: "Marc", replaceWith: "Marco")])
        XCTAssertEqual(AssistantTextProcessing.process(raw, style: .literal, vocabulary: vocabulary,
                          formatting: .init(removeFillerWords: true), recognizeCorrections: true), raw)
        XCTAssertEqual(AssistantTextProcessing.process(raw, style: .polished, vocabulary: vocabulary,
                          formatting: .init(), recognizeCorrections: true), "Send it to Marco.")
    }
}
