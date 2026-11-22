import XCTest
import WhiskerFlowCore
@testable import WhiskerFlow

/// The monitor is never started here, so no event monitor or tap is installed.
@MainActor
final class ShortcutTapFallbackTests: XCTestCase {
    private let f5 = KeyCombo(keyCode: 96)

    private func event(_ kind: ShortcutEventFilter.EventKind, _ key: UInt16 = 96,
                       repeat isRepeat: Bool = false) -> ShortcutEventTap.Event {
        ShortcutEventTap.Event(kind: kind, keyCode: key, modifiers: [], isRepeat: isRepeat,
                               timestamp: ProcessInfo.processInfo.systemUptime)
    }

    func testWithoutATapTheMonitorIgnoresTapEventsAndKeepsObserving() {
        var transitions: [Bool] = []
        let monitor = HotkeyMonitor(combo: f5) { transitions.append($0) }
        // No tap reported active: the NSEvent monitors stay the only source.
        monitor.feed(event(.keyDown))
        monitor.feed(event(.keyUp))
        XCTAssertEqual(transitions, [])
    }

    func testTapDrivenMonitorCountsEachPressOnceAndKeepsItsStateWhenTheTapGoesAway() {
        var transitions: [Bool] = []
        let monitor = HotkeyMonitor(combo: f5) { transitions.append($0) }
        monitor.setDrivenByTap(true)
        monitor.feed(event(.keyDown))
        monitor.feed(event(.keyDown, repeat: true))
        XCTAssertEqual(transitions, [true])
        // The tap stops mid-press: the press is still held, so the observed release ends it.
        monitor.setDrivenByTap(false)
        monitor.feed(event(.keyUp))
        XCTAssertEqual(transitions, [true], "Once the tap is gone its events are ignored")
        monitor.setDrivenByTap(true)
        monitor.feed(event(.keyUp))
        XCTAssertEqual(transitions, [true, false])
    }

    func testSuspendedMonitorIgnoresTapEvents() {
        var transitions: [Bool] = []
        let monitor = HotkeyMonitor(combo: f5) { transitions.append($0) }
        monitor.setDrivenByTap(true)
        monitor.setSuspended(true)
        monitor.feed(event(.keyDown))
        XCTAssertEqual(transitions, [])
    }
}
