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
}
