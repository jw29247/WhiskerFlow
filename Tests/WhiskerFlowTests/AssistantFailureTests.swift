import Foundation
import XCTest
@testable import WhiskerFlow

private actor FailedAssistantTransport: AssistantAtlasTransport {
    let code: String
    init(code: String) { self.code = code }
    func call(operation: String, arguments: Data) async throws -> Data {
        let response: [String: Any] = operation == "getResult"
            ? ["contractVersion": 1, "status": "failed", "error": code]
            : ["contractVersion": 1, "jobReference": "synthetic_failed_job", "status": "queued"]
        return try JSONSerialization.data(withJSONObject: response)
    }
}

final class AssistantFailureTests: XCTestCase {
    @MainActor func testTerminalFailureExplainsSafeReasonWithoutLosingOriginal() async {
        let cases = [
            ("assistant_budget_exceeded", "daily AI budget"),
            ("assistant_provider_unavailable", "AI provider is unavailable"),
            ("assistant_invalid_output", "could not produce a valid result"),
            ("assistant_context_unavailable", "access to the source"),
            ("assistant_generation_timeout", "timed out"),
        ]
        for (code, expected) in cases {
            let controller = AssistantController()
            let transport = FailedAssistantTransport(code: code)
            controller.requestTransport = { transport }
            controller.setCloudEnabled(true)
            controller.rewriteInput = "Keep £150, not £500. Do not publish."
            await controller.rewrite(operation: "shorten")
            XCTAssertTrue(controller.message?.contains(expected) == true, "Missing explanation for \(code): \(controller.message ?? "nil")")
            XCTAssertEqual(controller.rewriteInput, "Keep £150, not £500. Do not publish.")
            XCTAssertTrue(controller.rewritePreview.isEmpty)
            XCTAssertNil(controller.saved.pendingJob)
        }
    }

    @MainActor func testUnknownFailureDoesNotDisplayUntrustedServerText() async {
        let controller = AssistantController()
        let transport = FailedAssistantTransport(code: "private_provider_payload_do_not_display")
        controller.requestTransport = { transport }
        controller.setCloudEnabled(true)
        controller.rewriteInput = "Retain the original."
        await controller.rewrite(operation: "shorten")
        XCTAssertEqual(controller.message, "Atlas could not finish this request. You can try a new request.")
        XCTAssertTrue(controller.rewritePreview.isEmpty)
    }
}
