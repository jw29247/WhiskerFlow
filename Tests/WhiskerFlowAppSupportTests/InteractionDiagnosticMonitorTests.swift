import AppKit
import XCTest
@testable import WhiskerFlowAppSupport

@MainActor
final class InteractionDiagnosticMonitorTests: XCTestCase {
    private let context = InteractionDiagnosticContext(
        appActive: true, visibleWindows: 1, accessibilityTrusted: true, secureInput: false, globeKeyUsage: .doNothing
    )

    func testTimerIsSlowAndCoalescedButActivationStillRefreshesAtOnce() {
        var published = 0
        let context = context
        let monitor = InteractionDiagnosticMonitor(read: { context }, publish: { _ in published += 1 })
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(published, 1, "Read once at start")
        XCTAssertEqual(monitor.timer?.timeInterval, 30)
        XCTAssertEqual(monitor.timer?.tolerance, 5)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(published, 2, "Activation is still recorded at once")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(published, 3)

        monitor.timer?.fire()
        XCTAssertEqual(published, 4)
    }

    func testStopRemovesTheTimerAndObservers() {
        var published = 0
        let context = context
        let monitor = InteractionDiagnosticMonitor(read: { context }, publish: { _ in published += 1 })
        monitor.start()
        monitor.stop()
        XCTAssertNil(monitor.timer)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(published, 1)
    }
}
