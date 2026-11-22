import XCTest
@testable import WhiskerFlowAppSupport

/// The watchdog's timing on a virtual clock: ticks at the cadence's interval,
/// and a main thread that stops answering at `stallStart` for `stallLength`.
final class MainThreadHealthCadenceTests: XCTestCase {
    /// Runs the probe for 20 s and returns the stalls it reported.
    private func stallsReported(tick: TimeInterval, stallStart: TimeInterval, stallLength: TimeInterval) -> [ResponsivenessProbe.Event] {
        var probe = ResponsivenessProbe()
        var reported: [ResponsivenessProbe.Event] = []
        let stallEnd = stallStart + stallLength
        var now: TimeInterval = 0
        while now < 20 {
            for event in probe.tick(at: now) {
                switch event {
                case let .enqueue(id):
                    // The main queue answers at once, or when the stall ends.
                    let answeredAt = now >= stallStart && now < stallEnd ? stallEnd : now
                    if answeredAt == now {
                        reported += probe.acknowledge(id, at: now)
                    } else {
                        // Ticks continue while it is blocked.
                        var t = now + tick
                        while t < answeredAt {
                            reported += probe.tick(at: t).filter { if case .stalled = $0 { return true } else { return false } }
                            t += tick
                        }
                        reported += probe.acknowledge(id, at: answeredAt)
                        now = t - tick
                    }
                default:
                    reported.append(event)
                }
            }
            now += tick
        }
        return reported.filter { if case .stalled = $0 { return true } else { return false } }
    }

    func testDictationKeepsTheFastCadence() {
        XCTAssertEqual(MainThreadHealthCadence.tick(active: true), 0.25)
        XCTAssertEqual(MainThreadHealthCadence.tick(active: false), 1)
        XCTAssertEqual(MainThreadHealthCadence.leeway(forTick: 0.25), 0.05, "Unchanged from the fixed 250 ms timer")
    }

    func testDuringDictationEveryStallOfTwoAndAQuarterSecondsIsReported() {
        for offset in stride(from: 0.0, to: 0.25, by: 0.05) {
            let stalls = stallsReported(tick: MainThreadHealthCadence.activeTick, stallStart: 5 + offset, stallLength: 2.25)
            XCTAssertEqual(stalls.count, 1, "offset \(offset)")
        }
    }

    func testWhileIdleEveryStallOfThreeSecondsIsReported() {
        for offset in stride(from: 0.0, to: 1.0, by: 0.1) {
            let stalls = stallsReported(tick: MainThreadHealthCadence.idleTick, stallStart: 5 + offset, stallLength: 3)
            XCTAssertEqual(stalls.count, 1, "offset \(offset)")
        }
    }

    func testWhileIdleAStallJustOverTwoSecondsCanGoUnreported() {
        // The trade-off of the idle cadence: a 2.25 s stall that starts just
        // after a probe was answered is measured from the next tick.
        let missed = stallsReported(tick: MainThreadHealthCadence.idleTick, stallStart: 5.01, stallLength: 2.25)
        XCTAssertEqual(missed, [])
        let caught = stallsReported(tick: MainThreadHealthCadence.activeTick, stallStart: 5.01, stallLength: 2.25)
        XCTAssertEqual(caught.count, 1)
    }

    func testIdleTicksAreFarApartFromTheSchedulingGapThreshold() {
        // Five seconds between ticks is read as the process not being scheduled.
        var probe = ResponsivenessProbe()
        var now: TimeInterval = 0
        var events: [ResponsivenessProbe.Event] = []
        while now < 30 {
            for event in probe.tick(at: now) {
                if case let .enqueue(id) = event { events += probe.acknowledge(id, at: now + 0.001) } else { events.append(event) }
            }
            now += MainThreadHealthCadence.idleTick + MainThreadHealthCadence.leeway(forTick: MainThreadHealthCadence.idleTick)
        }
        XCTAssertEqual(events, [])
    }

    func testPeriodicRowsKeepTheirIntervalsWhateverTheTick() {
        // Resource snapshots: every 15 s during a dictation, every 60 s idle.
        for (active, expectedResources) in [(true, 240), (false, 60)] {
            let tick = MainThreadHealthCadence.tick(active: active)
            var schedule = MainThreadHealthLogSchedule(start: 100)
            var resources = 0
            var heartbeats = 0
            var now: TimeInterval = 100
            while now < 100 + 3600 {
                now += tick
                let due = schedule.due(at: now, active: active)
                if due.resources { resources += 1 }
                if due.heartbeat { heartbeats += 1 }
            }
            XCTAssertEqual(resources, expectedResources, "active \(active)")
            XCTAssertEqual(heartbeats, 60, "active \(active)")
        }
    }

    func testADictationStartingAfterAnIdleMinuteGetsASnapshotWithinFifteenSeconds() {
        var schedule = MainThreadHealthLogSchedule(start: 0)
        XCTAssertFalse(schedule.due(at: 30, active: false).resources)
        XCTAssertTrue(schedule.due(at: 30.25, active: true).resources, "Already 30 s since the last snapshot")
        XCTAssertFalse(schedule.due(at: 45, active: true).resources)
        XCTAssertTrue(schedule.due(at: 45.25, active: true).resources)
    }
}
