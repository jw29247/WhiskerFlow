import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

@MainActor
final class AutomaticCorrectionLearnerTests: XCTestCase {
    func testDictationPreemptsAssessmentAndOnlyLatestEditIsLearned() async throws {
        let learner = AutomaticCorrectionLearner(debounce: .zero)
        var calls = 0
        var learned: [VocabularyCorrection] = []
        learner.assess = { edit in
            calls += 1
            try await Task.sleep(for: .milliseconds(80))
            return edit.candidates
        }
        learner.onValidated = { _, approved in learned += approved }
        learner.configure(enabled: true)
        let session = UUID()
        learner.enqueue(original: "Ask zorbit about it.", edited: "Ask Zorb about it.", sessionID: session, application: "Test")
        try await wait { calls == 1 }
        learner.setBusy(true)
        learner.enqueue(original: "Ask zorbit about it.", edited: "Ask Zorblet about it.", sessionID: session, application: "Test")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(learned.isEmpty)
        learner.setBusy(false)
        try await wait { learned.count == 1 }
        XCTAssertEqual(learned.first?.replaceWith, "Zorblet")
        learner.stop()
    }

    func testUnavailableModelDoesNotLearnOrRetryUntilResumed() async throws {
        let learner = AutomaticCorrectionLearner(debounce: .zero)
        var calls = 0
        var learned = false
        learner.assess = { _ in calls += 1; throw CleanupFailure.unavailable }
        learner.onValidated = { _, _ in learned = true }
        learner.configure(enabled: true)
        learner.enqueue(original: "Ask zorbit about it.", edited: "Ask Zorblet about it.", sessionID: UUID(), application: "Test")
        try await wait { calls == 1 }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(learned)
        learner.resume()
        try await wait { calls == 2 }
        learner.configure(enabled: false)
        learner.resume()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(calls, 2)
    }

    func testClassifierCannotInventCorrections() async {
        let learner = AutomaticCorrectionLearner(debounce: .zero)
        let done = expectation(description: "validated")
        learner.assess = { _ in [.init(find: "invented", replaceWith: "Unrelated")] }
        learner.onValidated = { _, approved in XCTAssertTrue(approved.isEmpty); done.fulfill() }
        learner.configure(enabled: true)
        learner.enqueue(original: "Ask zorbit about it.", edited: "Ask Zorblet about it.", sessionID: UUID(), application: "Test")
        await fulfillment(of: [done], timeout: 1)
        learner.stop()
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected queue transition did not occur")
    }
}
