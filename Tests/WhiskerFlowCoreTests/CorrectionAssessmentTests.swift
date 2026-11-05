import XCTest
@testable import WhiskerFlowCore

final class CorrectionAssessmentTests: XCTestCase {
    func testEditsSupplyBoundedContextAndRejectFactChangesBeforeInference() {
        XCTAssertTrue(CorrectionEdit(original: "Send 15 copies.", edited: "Send 50 copies.").candidates.isEmpty)
        XCTAssertTrue(CorrectionEdit(original: "Come on Wednesday.", edited: "Come on Thursday.").candidates.isEmpty)
        XCTAssertTrue(CorrectionEdit(original: "Yes, send it.", edited: "No, send it.").candidates.isEmpty)
        let edit = CorrectionEdit(original: "Ask kubernetis about it.", edited: "Ask Kubernetes about it.")
        XCTAssertEqual(edit.candidates, [.init(find: "kubernetis", replaceWith: "Kubernetes")])
        XCTAssertTrue(CorrectionAssessment.prompt(for: edit.candidates[0], edit: edit).contains("Ask Kubernetes about it."))
        XCTAssertTrue(CorrectionAssessment.approved("YES\n"))
        XCTAssertFalse(CorrectionAssessment.approved("YES, here is why"))
        XCTAssertFalse(CorrectionAssessment.approved("NO"))
    }

    func testAcceptedCleanupIsNotRunThroughReplacementsAgain() {
        let vocabulary = Vocabulary(rules: [.init(find: "whisper", replaceWith: "WhiskerFlow")])
        let text = "Please whisper so nobody hears us."
        XCTAssertEqual(AssistantTextProcessing.finish(text, usesCleanup: true, tone: .formal, vocabulary: vocabulary,
            formatting: .init(), recognizeCorrections: true), text)
        XCTAssertEqual(AssistantTextProcessing.finish("Open whisper.", usesCleanup: false, tone: .formal, vocabulary: vocabulary,
            formatting: .init(), recognizeCorrections: true), "Open WhiskerFlow.")
    }
}
