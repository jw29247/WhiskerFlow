import XCTest
@testable import WhiskerFlowAppSupport

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func testStaleSessionCannotAdvanceOrCompleteNewerSession() {
        let coordinator = RecordingCoordinator()
        let first = coordinator.requestStart()
        XCTAssertNotNil(first)
        XCTAssertTrue(coordinator.didStart(first!))
        XCTAssertTrue(coordinator.requestFinish(first!))
        XCTAssertTrue(coordinator.didFinish(first!))

        let second = coordinator.requestStart()
        XCTAssertNotNil(second)
        XCTAssertFalse(coordinator.didStart(first!))
        XCTAssertFalse(coordinator.didFinish(first!))
        XCTAssertEqual(coordinator.phase, .preparing(second!))
    }

    func testRapidStartIsIgnoredWhilePreparingOrFinishing() {
        let coordinator = RecordingCoordinator()
        let session = coordinator.requestStart()
        XCTAssertNil(coordinator.requestStart())
        XCTAssertTrue(coordinator.didStart(session!))
        XCTAssertTrue(coordinator.requestFinish(session!))
        XCTAssertNil(coordinator.requestStart())
        XCTAssertTrue(coordinator.didFinish(session!))
        XCTAssertNotNil(coordinator.requestStart())
    }

    func testDisconnectUsesFinishingStateAndPreservesReason() {
        let coordinator = RecordingCoordinator()
        let session = coordinator.requestStart()!
        XCTAssertTrue(coordinator.didStart(session))
        XCTAssertTrue(coordinator.requestFinish(session, reason: .deviceDisconnected))
        XCTAssertEqual(coordinator.phase, .finishing(session))
        XCTAssertEqual(coordinator.stopReason, .deviceDisconnected)
    }

    func testStopIsIdempotentAndCannotFinishDuringPreparation() {
        let coordinator = RecordingCoordinator()
        let session = coordinator.requestStart()!
        XCTAssertFalse(coordinator.requestFinish(session))
        XCTAssertEqual(coordinator.phase, .preparing(session))

        XCTAssertTrue(coordinator.didStart(session))
        XCTAssertTrue(coordinator.requestFinish(session))
        XCTAssertFalse(coordinator.requestFinish(session))
        XCTAssertTrue(coordinator.didFinish(session))
        XCTAssertFalse(coordinator.didFinish(session))
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testFailureRecoversEveryActivePhaseAndRejectsStaleTokens() {
        let coordinator = RecordingCoordinator()
        let preparing = coordinator.requestStart()!
        XCTAssertFalse(coordinator.fail(UUID()))
        XCTAssertTrue(coordinator.fail(preparing))
        XCTAssertEqual(coordinator.phase, .idle)

        let recording = coordinator.requestStart()!
        XCTAssertTrue(coordinator.didStart(recording))
        XCTAssertTrue(coordinator.fail(recording))
        XCTAssertEqual(coordinator.phase, .idle)

        let finishing = coordinator.requestStart()!
        XCTAssertTrue(coordinator.didStart(finishing))
        XCTAssertTrue(coordinator.requestFinish(finishing))
        XCTAssertTrue(coordinator.fail(finishing))
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testForceIdleRecoversEveryActivePhaseAndReportsWhetherItActed() throws {
        let coordinator = RecordingCoordinator()
        XCTAssertFalse(coordinator.forceIdle())

        let preparing = try XCTUnwrap(coordinator.requestStart())
        XCTAssertEqual(coordinator.phase, .preparing(preparing))
        XCTAssertTrue(coordinator.forceIdle())
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.stopReason, .failed)
        XCTAssertFalse(coordinator.forceIdle())

        let recording = try XCTUnwrap(coordinator.requestStart())
        XCTAssertTrue(coordinator.didStart(recording))
        XCTAssertTrue(coordinator.forceIdle())
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.stopReason, .failed)

        let finishing = try XCTUnwrap(coordinator.requestStart())
        XCTAssertTrue(coordinator.didStart(finishing))
        XCTAssertTrue(coordinator.requestFinish(finishing, reason: .userReleased))
        XCTAssertTrue(coordinator.forceIdle())
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertEqual(coordinator.stopReason, .failed)
    }

    func testForceIdleRejectsStaleTokensAndAllowsANewSession() throws {
        let coordinator = RecordingCoordinator()
        let stuck = try XCTUnwrap(coordinator.requestStart())
        XCTAssertTrue(coordinator.didStart(stuck))
        XCTAssertTrue(coordinator.requestFinish(stuck))
        XCTAssertTrue(coordinator.forceIdle())

        XCTAssertFalse(coordinator.didFinish(stuck))
        XCTAssertFalse(coordinator.requestFinish(stuck))

        let next = try XCTUnwrap(coordinator.requestStart())
        XCTAssertEqual(coordinator.phase, .preparing(next))
        XCTAssertNil(coordinator.stopReason)
        XCTAssertTrue(coordinator.didStart(next))
        XCTAssertTrue(coordinator.requestFinish(next))
        XCTAssertTrue(coordinator.didFinish(next))
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testOneHundredRapidSessionsAlwaysRecoverToIdle() throws {
        let coordinator = RecordingCoordinator()

        for _ in 0..<100 {
            let session = try XCTUnwrap(coordinator.requestStart())
            XCTAssertTrue(coordinator.didStart(session))
            XCTAssertTrue(coordinator.requestFinish(session, reason: .userReleased))
            XCTAssertTrue(coordinator.didFinish(session))
            XCTAssertEqual(coordinator.phase, .idle)
        }
    }

    // MARK: - Discard (Esc)

    func testDiscardWhileRecordingFinishesWithoutATranscriptAndAllowsTheNextDictation() {
        let coordinator = RecordingCoordinator()
        let session = coordinator.requestStart()!
        XCTAssertTrue(coordinator.didStart(session))
        XCTAssertEqual(coordinator.requestDiscard(), .recording(session))
        XCTAssertEqual(coordinator.phase, .finishing(session))
        XCTAssertEqual(coordinator.stopReason, .cancelled)
        // A key release arriving after Esc must not start a normal finish.
        XCTAssertFalse(coordinator.requestFinish(session))
        XCTAssertTrue(coordinator.didFinish(session))
        XCTAssertEqual(coordinator.phase, .idle)

        let next = coordinator.requestStart()!
        XCTAssertTrue(coordinator.didStart(next))
        XCTAssertTrue(coordinator.requestFinish(next))
        XCTAssertEqual(coordinator.stopReason, .userReleased)
        XCTAssertTrue(coordinator.didFinish(next))
    }

    func testDiscardWhilePreparingHoldsTheSessionUntilTheStartInFlightCleansUp() {
        let coordinator = RecordingCoordinator()
        let session = coordinator.requestStart()!
        XCTAssertEqual(coordinator.requestDiscard(), .preparing(session))
        XCTAssertEqual(coordinator.phase, .finishing(session))
        XCTAssertEqual(coordinator.stopReason, .cancelled)
        XCTAssertNil(coordinator.requestStart(), "A new press must wait until the discarded start has cleaned up")
        XCTAssertFalse(coordinator.didStart(session), "The microphone that finishes opening must see its session ended")
        XCTAssertFalse(coordinator.requestFinish(session))
        XCTAssertTrue(coordinator.completeDiscard(session))
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(coordinator.completeDiscard(session))
        XCTAssertNotNil(coordinator.requestStart())
    }

    func testCompleteDiscardDoesNotEndANormalSession() {
        let coordinator = RecordingCoordinator()
        let session = coordinator.requestStart()!
        XCTAssertFalse(coordinator.completeDiscard(session))
        XCTAssertTrue(coordinator.didStart(session))
        XCTAssertTrue(coordinator.requestFinish(session))
        XCTAssertFalse(coordinator.completeDiscard(session), "A normal finish is completed by didFinish only")
        XCTAssertEqual(coordinator.phase, .finishing(session))
        XCTAssertTrue(coordinator.didFinish(session))
    }

    func testDiscardedStartThatFailsStillLeavesTheCoordinatorUsable() {
        let coordinator = RecordingCoordinator()
        let session = coordinator.requestStart()!
        coordinator.requestDiscard()
        XCTAssertTrue(coordinator.fail(session))
        XCTAssertFalse(coordinator.completeDiscard(session))
        XCTAssertEqual(coordinator.phase, .idle)
        let next = coordinator.requestStart()!
        XCTAssertFalse(coordinator.completeDiscard(session), "A stale discard must not end the next session")
        XCTAssertEqual(coordinator.phase, .preparing(next))
    }

    func testDiscardDoesNothingWhenIdleOrTranscribing() {
        let coordinator = RecordingCoordinator()
        XCTAssertNil(coordinator.requestDiscard())
        XCTAssertEqual(coordinator.phase, .idle)

        let session = coordinator.requestStart()!
        XCTAssertTrue(coordinator.didStart(session))
        XCTAssertTrue(coordinator.requestFinish(session))
        XCTAssertNil(coordinator.requestDiscard(), "A finished recording being transcribed is not discarded")
        XCTAssertEqual(coordinator.phase, .finishing(session))
        XCTAssertEqual(coordinator.stopReason, .userReleased)
    }

    func testDiscardablePhases() {
        let id = UUID()
        XCTAssertFalse(RecordingPhase.idle.isDiscardable)
        XCTAssertTrue(RecordingPhase.preparing(id).isDiscardable)
        XCTAssertTrue(RecordingPhase.recording(id).isDiscardable)
        XCTAssertFalse(RecordingPhase.finishing(id).isDiscardable)
    }

    func testPhaseChangesAreReportedOnceEach() throws {
        let coordinator = RecordingCoordinator()
        var phases: [RecordingPhase] = []
        coordinator.onPhaseChange = { phases.append($0) }
        let session = try XCTUnwrap(coordinator.requestStart())
        XCTAssertNil(coordinator.requestStart(), "a refused start changes nothing")
        coordinator.didStart(session)
        coordinator.requestFinish(session)
        coordinator.didFinish(session)
        XCTAssertEqual(phases, [.preparing(session), .recording(session), .finishing(session), .idle])
    }
}
