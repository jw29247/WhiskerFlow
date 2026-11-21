import Foundation
import XCTest
@testable import WhiskerFlowAppSupport

/// Virtual time: `sleep` advances it instantly and the deadline timer fires
/// only when the test says so.
private final class ManualVerificationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var slept: [TimeInterval] = []
    private var scheduled: [(delay: TimeInterval, work: @Sendable () -> Void)] = []

    var sleeps: [TimeInterval] { lock.withLock { slept } }
    var scheduledDelays: [TimeInterval] { lock.withLock { scheduled.map { $0.delay } } }

    var clock: PasteVerificationClock {
        PasteVerificationClock(
            now: { self.lock.withLock { self.time } },
            sleep: { interval in
                self.lock.withLock {
                    self.slept.append(interval)
                    self.time += interval
                }
            },
            schedule: { delay, work in self.lock.withLock { self.scheduled.append((delay, work)) } }
        )
    }

    /// Fires every scheduled deadline, as if its delay had passed.
    func fireScheduled() {
        let due = lock.withLock { () -> [@Sendable () -> Void] in
            defer { scheduled.removeAll() }
            return scheduled.map { $0.work }
        }
        due.forEach { $0() }
    }
}

private final class ThreadRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: Bool?
    var probeRanOnMainThread: Bool? { lock.withLock { onMain } }
    func record() { lock.withLock { onMain = Thread.isMainThread } }
}

final class PasteVerificationTests: XCTestCase {
    @MainActor
    func testUnresponsiveDestinationCannotBlockMainActorOrDeadline() async {
        let clock = ManualVerificationClock()
        let thread = ThreadRecord()
        let probeEntered = expectation(description: "probe is running")
        let releaseProbe = DispatchSemaphore(value: 0)
        let task = Task { await PasteVerification.verify(timeout: 0.05, minimumWait: 0, clock: clock.clock) {
            thread.record()
            probeEntered.fulfill()
            releaseProbe.wait()
            return true
        } }
        // The probe is stuck in the destination, yet this main-actor test
        // keeps running and can wait for it.
        await fulfillment(of: [probeEntered], timeout: 10)
        XCTAssertEqual(thread.probeRanOnMainThread, false, "AX work must not run on the main actor")
        XCTAssertEqual(clock.scheduledDelays, [0.05])
        clock.fireScheduled()
        let result = await task.value
        releaseProbe.signal()
        XCTAssertFalse(result, "Late verification must not turn timeout into success")
    }

    func testSuccessfulVerificationHonoursClipboardConsumptionWindow() async {
        let clock = ManualVerificationClock()
        let result = await PasteVerification.verify(timeout: 0.2, minimumWait: 0.04, clock: clock.clock) { true }
        XCTAssertTrue(result)
        XCTAssertEqual(clock.sleeps, [0.04], "a confirmed paste still waits out the clipboard window")
    }
}
