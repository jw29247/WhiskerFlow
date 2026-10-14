import Foundation
import XCTest
@testable import WhiskerFlow

final class AudioUnitRunningStateTests: XCTestCase {
    /// Teardown holds the unit lock while it waits for the I/O callback to
    /// return. A property query inside that callback creates a lock cycle.
    func testNotificationReturnsWhileTheAudioUnitIsLocked() {
        let unitLock = NSLock()
        let queried = expectation(description: "Running state queried after the callback returns")
        let returned = DispatchSemaphore(value: 0)
        let state = AudioUnitRunningState {
            unitLock.withLock {
                queried.fulfill()
                return true
            }
        }
        unitLock.lock()
        DispatchQueue.global().async {
            state.propertyChanged()
            returned.signal()
        }
        let result = returned.wait(timeout: .now() + 0.2)
        // Always break the simulated lock cycle, even on the old implementation.
        unitLock.unlock()
        XCTAssertEqual(result, .success, "The CoreAudio callback must return without querying the locked unit")
        wait(for: [queried], timeout: 2)
    }

    func testQueuedNotificationCannotQueryADisposedUnit() {
        let queue = DispatchQueue(label: "test.running-state")
        queue.suspend()
        let state = AudioUnitRunningState(queue: queue) {
            XCTFail("A queued notification queried a disposed audio unit")
            return true
        }
        state.propertyChanged()
        state.invalidate()
        queue.resume()
        queue.sync {}
        XCTAssertFalse(state.isRunning)
    }

    func testWatchdogCanReadStateWhileAPropertyQueryIsBlocked() {
        let entered = expectation(description: "Property query started")
        let release = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.running-state")
        let state = AudioUnitRunningState(queue: queue) {
            entered.fulfill()
            release.wait()
            return false
        }
        state.setRunning(true)
        DispatchQueue.global().async { state.propertyChanged() }
        wait(for: [entered], timeout: 2)
        let readReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(state.isRunning)
            readReturned.signal()
        }
        let result = readReturned.wait(timeout: .now() + 0.2)
        release.signal()
        XCTAssertEqual(result, .success, "The watchdog must not wait for a blocked property query")
        state.invalidate()
        queue.sync {}
        XCTAssertFalse(state.isRunning)
    }
}
