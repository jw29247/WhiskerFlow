import XCTest
@testable import WhiskerFlowAppSupport

@MainActor
final class SecureInputMonitorTests: XCTestCase {
    func testNoticeAppearsAndClearsWithSecureInputAndPollsOnlyWhileShown() {
        var secureInput = false
        var changes: [Bool] = []
        let monitor = SecureInputMonitor(probe: { secureInput }, onChange: { changes.append($0) })
        defer { monitor.stop() }

        monitor.refresh()
        XCTAssertFalse(monitor.isActive)
        XCTAssertFalse(monitor.isPolling, "Nothing is polled while Secure Input is off")
        XCTAssertEqual(changes, [])

        secureInput = true
        monitor.refresh()
        XCTAssertTrue(monitor.isActive)
        XCTAssertTrue(monitor.isPolling, "A slow check runs so the notice clears by itself")
        monitor.refresh()
        XCTAssertEqual(changes, [true], "An unchanged state is not reported again")

        secureInput = false
        monitor.refresh()
        XCTAssertFalse(monitor.isActive)
        XCTAssertFalse(monitor.isPolling)
        XCTAssertEqual(changes, [true, false])
    }

    func testStopEndsPolling() {
        let monitor = SecureInputMonitor(probe: { true }, onChange: { _ in })
        monitor.refresh()
        XCTAssertTrue(monitor.isPolling)
        monitor.stop()
        XCTAssertFalse(monitor.isPolling)
    }

    func testNoticeWording() {
        XCTAssertEqual(SecureInputMonitor.notice, "Secure input is on in another app, so the shortcut is paused.")
    }
}
