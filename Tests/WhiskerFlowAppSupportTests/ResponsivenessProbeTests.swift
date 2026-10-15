import XCTest
@testable import WhiskerFlowAppSupport

final class ResponsivenessProbeTests: XCTestCase {
    func testReportsOneStallAndRecoveryForOneOutstandingProbe() {
        var probe = ResponsivenessProbe()
        XCTAssertEqual(probe.tick(at: 10), [.enqueue(1)])
        XCTAssertEqual(probe.tick(at: 11), [])
        XCTAssertEqual(probe.tick(at: 12), [.stalled(2)])
        XCTAssertEqual(probe.tick(at: 13), [])
        XCTAssertEqual(probe.acknowledge(1, at: 13.5), [.recovered(3.5)])
        XCTAssertEqual(probe.tick(at: 14), [.enqueue(2)])
    }

    func testRecoveryBetweenTimerTicksStillReportsDelay() {
        var probe = ResponsivenessProbe()
        XCTAssertEqual(probe.tick(at: 10), [.enqueue(1)])
        XCTAssertEqual(probe.acknowledge(1, at: 12.5), [.stalled(2.5), .recovered(2.5)])
    }

    func testWholeProcessSchedulingGapIsNotAUIFreeze() {
        var probe = ResponsivenessProbe()
        XCTAssertEqual(probe.tick(at: 10), [.enqueue(1)])
        XCTAssertEqual(probe.tick(at: 100), [.monitoringGap(90), .enqueue(2)])
        XCTAssertEqual(probe.acknowledge(1, at: 100.1), [])
        XCTAssertEqual(probe.acknowledge(2, at: 100.2), [])
    }

    func testLateAcknowledgementDoesNotInventAFreezeAfterSchedulingGap() {
        var probe = ResponsivenessProbe()
        _ = probe.tick(at: 10)
        XCTAssertEqual(probe.acknowledge(1, at: 100), [.monitoringGap(90)])
    }

    func testSleepResetsOutstandingProbeAndIgnoresOldAcknowledgement() {
        var probe = ResponsivenessProbe()
        _ = probe.tick(at: 10)
        probe.reset()
        XCTAssertEqual(probe.tick(at: 100), [.enqueue(2)])
        XCTAssertEqual(probe.acknowledge(1, at: 100.1), [])
        XCTAssertEqual(probe.tick(at: 102), [.stalled(2)])
    }
}
