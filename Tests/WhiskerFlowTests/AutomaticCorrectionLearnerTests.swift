import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

/// Stands in for the model: each assessment is held until the test releases
/// it, like a model call that ignores cancellation, so no test depends on
/// how long a real call or a sleep takes.
@MainActor
private final class HeldAssessments {
    private(set) var edits: [CorrectionEdit] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var entryWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func assess(_ edit: CorrectionEdit) async -> [VocabularyCorrection] {
        edits.append(edit)
        if let waiter = entryWaiter, edits.count >= waiter.count {
            entryWaiter = nil
            waiter.continuation.resume()
        }
        await withCheckedContinuation { held.append($0) }
        return edit.candidates
    }

    /// Returns once `count` assessments have started.
    func untilStarted(_ count: Int) async {
        guard edits.count < count else { return }
        await withCheckedContinuation { entryWaiter = (count, $0) }
    }

    func releaseAll() {
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

@MainActor
final class AutomaticCorrectionLearnerTests: XCTestCase {
    func testDictationPreemptsAssessmentAndOnlyLatestEditIsLearned() async throws {
        let learner = AutomaticCorrectionLearner(debounce: .zero)
        let model = HeldAssessments()
        var learned: [VocabularyCorrection] = []
        learner.assess = { await model.assess($0) }
        learner.onValidated = { _, approved in learned += approved }
        learner.configure(enabled: true)
        let session = UUID()
        learner.enqueue(original: "Ask zorbit about it.", edited: "Ask Zorb about it.", sessionID: session, application: "Test")
        await model.untilStarted(1)

        // A dictation starts while the model is still assessing the first edit.
        learner.setBusy(true)
        let preempted = try XCTUnwrap(learner.task)
        learner.enqueue(original: "Ask zorbit about it.", edited: "Ask Zorblet about it.", sessionID: session, application: "Test")
        // The pre-empted call returns late; its answer must not be used.
        model.releaseAll()
        await preempted.value
        XCTAssertTrue(learned.isEmpty)
        XCTAssertNil(learner.task, "nothing is assessed while dictating")

        learner.setBusy(false)
        await model.untilStarted(2)
        XCTAssertEqual(model.edits.last?.edited, "Ask Zorblet about it.")
        model.releaseAll()
        await learner.task?.value
        XCTAssertEqual(learned.map(\.replaceWith), ["Zorblet"])
        learner.stop()
    }

    func testUnavailableModelDoesNotLearnOrRetryUntilResumed() async {
        let learner = AutomaticCorrectionLearner(debounce: .zero)
        var calls = 0
        var learned = false
        learner.assess = { _ in calls += 1; throw CleanupFailure.unavailable }
        learner.onValidated = { _, _ in learned = true }
        learner.configure(enabled: true)
        learner.enqueue(original: "Ask zorbit about it.", edited: "Ask Zorblet about it.", sessionID: UUID(), application: "Test")
        await learner.task?.value
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(learned)
        XCTAssertNil(learner.task, "no retry is scheduled")
        learner.resume()
        await learner.task?.value
        XCTAssertEqual(calls, 2)
        learner.configure(enabled: false)
        learner.resume()
        XCTAssertNil(learner.task, "a disabled learner starts nothing")
        XCTAssertEqual(calls, 2)
    }

    func testEditsSettleForTwoSecondsBeforeAssessment() {
        XCTAssertEqual(AutomaticCorrectionLearner().debounce, .seconds(2))
    }

    func testClassifierCannotInventCorrections() async {
        let learner = AutomaticCorrectionLearner(debounce: .zero)
        var validated: [[VocabularyCorrection]] = []
        learner.assess = { _ in [.init(find: "invented", replaceWith: "Unrelated")] }
        learner.onValidated = { _, approved in validated.append(approved) }
        learner.configure(enabled: true)
        learner.enqueue(original: "Ask zorbit about it.", edited: "Ask Zorblet about it.", sessionID: UUID(), application: "Test")
        await learner.task?.value
        XCTAssertEqual(validated, [[]])
        learner.stop()
    }
}
