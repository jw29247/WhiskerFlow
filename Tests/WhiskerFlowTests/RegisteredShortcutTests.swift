import AppKit
import Carbon.HIToolbox
import XCTest
import WhiskerFlowAppSupport
import WhiskerFlowCore
@testable import WhiskerFlow

/// Stands in for Carbon so no real hot key is registered on this Mac.
@MainActor
private final class RecordingRegistrar: ShortcutRegistrar {
    var active: [RegisteredShortcut: KeyCombo] = [:]
    func register(_ shortcut: RegisteredShortcut, combo: KeyCombo) -> Bool {
        active[shortcut] = combo
        return true
    }

    func unregister(_ shortcut: RegisteredShortcut) { active[shortcut] = nil }
}

@MainActor
final class RegisteredShortcutTests: XCTestCase {
    private let ctrlOptSpace = KeyCombo(keyCode: 49, modifiers: [.control, .option])
    private let meeting = KeyCombo(keyCode: 15, modifiers: [.command, .option, .shift])

    override func setUp() {
        super.setUp()
        // HotkeyMonitor's existing transition log reads `NSApp`, which only
        // exists once the shared application has been created. Creating it
        // installs nothing.
        _ = NSApplication.shared
    }

    private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                          isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: " ", charactersIgnoringModifiers: " ",
                         isARepeat: isRepeat, keyCode: keyCode)!
    }

    // MARK: - HotkeyMonitor: one source per press

    func testRegisteredShortcutIsDrivenOnlyByTheHotKey() {
        var transitions: [Bool] = []
        let monitor = HotkeyMonitor(combo: ctrlOptSpace) { transitions.append($0) }
        monitor.setRegistered(true)

        monitor.handleRegisteredHotKey(pressed: true, eventTime: ProcessInfo.processInfo.systemUptime)
        // Should the observing monitors also see the key, it is not counted again.
        monitor.handleKey(keyEvent(.keyDown, keyCode: 49, modifiers: [.control, .option]), source: "global")
        monitor.handleKey(keyEvent(.keyUp, keyCode: 49, modifiers: [.control, .option]), source: "global")
        XCTAssertEqual(transitions, [true])
        monitor.handleRegisteredHotKey(pressed: false, eventTime: ProcessInfo.processInfo.systemUptime)
        XCTAssertEqual(transitions, [true, false])
    }

    func testUnregisteredShortcutKeepsTheObservingPath() {
        var transitions: [Bool] = []
        let monitor = HotkeyMonitor(combo: ctrlOptSpace) { transitions.append($0) }
        monitor.handleRegisteredHotKey(pressed: true, eventTime: 0)
        XCTAssertTrue(transitions.isEmpty, "hot key events are ignored unless registered")
        monitor.handleKey(keyEvent(.keyDown, keyCode: 49, modifiers: [.control, .option]), source: "global")
        monitor.handleKey(keyEvent(.keyUp, keyCode: 49, modifiers: [.control, .option]), source: "global")
        XCTAssertEqual(transitions, [true, false])
    }

    func testObservedEscapeStillDiscardsWhileTheShortcutIsRegistered() {
        let monitor = HotkeyMonitor(combo: ctrlOptSpace) { _ in }
        var discards = 0
        monitor.onDiscardKey = { discards += 1 }
        monitor.setRegistered(true)
        monitor.handleKey(keyEvent(.keyDown, keyCode: 53, modifiers: []), source: "global")
        XCTAssertEqual(discards, 1)
    }

    func testSuspendedMonitorIgnoresTheHotKeyAndReleasesAPressInProgress() {
        var transitions: [Bool] = []
        let monitor = HotkeyMonitor(combo: ctrlOptSpace) { transitions.append($0) }
        monitor.setRegistered(true)
        monitor.handleRegisteredHotKey(pressed: true, eventTime: 0)
        monitor.setSuspended(true)
        monitor.handleRegisteredHotKey(pressed: true, eventTime: 0)
        XCTAssertEqual(transitions, [true, false])
    }

    // MARK: - Esc window following the recording phase

    /// Mirrors AppState: the window follows `RecordingPhase.isDiscardable`.
    private func makeWindow() -> (RecordingCoordinator, RegisteredShortcutController, RecordingRegistrar) {
        let registrar = RecordingRegistrar()
        let controller = RegisteredShortcutController(
            registrar: registrar, dictationCombo: HotkeyTrigger.fn.presetCombo!, meetingCombo: meeting
        )
        controller.start()
        let coordinator = RecordingCoordinator()
        coordinator.onPhaseChange = { controller.setDiscardWindowOpen($0.isDiscardable) }
        return (coordinator, controller, registrar)
    }

    func testEscapeWindowAcrossANormalDictation() throws {
        let (coordinator, _, registrar) = makeWindow()
        XCTAssertNil(registrar.active[.discard])
        let id = try XCTUnwrap(coordinator.requestStart())
        XCTAssertNotNil(registrar.active[.discard], "registered while the microphone opens")
        coordinator.didStart(id)
        XCTAssertNotNil(registrar.active[.discard], "and while recording")
        coordinator.requestFinish(id)
        XCTAssertNil(registrar.active[.discard], "removed as soon as recording ends")
        coordinator.didFinish(id)
        XCTAssertNil(registrar.active[.discard])
    }

    func testEscapeWindowClosesOnDiscardWhileRecording() throws {
        let (coordinator, controller, registrar) = makeWindow()
        let id = try XCTUnwrap(coordinator.requestStart())
        coordinator.didStart(id)
        XCTAssertEqual(controller.handle(.discard, pressed: true), .discard)
        _ = coordinator.requestDiscard()
        XCTAssertNil(registrar.active[.discard])
        coordinator.didFinish(id)
        XCTAssertNil(registrar.active[.discard])
    }

    func testEscapeWindowClosesOnDiscardWhileOpening() throws {
        let (coordinator, _, registrar) = makeWindow()
        let id = try XCTUnwrap(coordinator.requestStart())
        _ = coordinator.requestDiscard()
        XCTAssertNil(registrar.active[.discard])
        _ = coordinator.completeDiscard(id)
        XCTAssertNil(registrar.active[.discard])
    }

    // MARK: - Carbon adapter (pure part only)

    func testCarbonModifierBits() {
        XCTAssertEqual(CarbonHotKeyRegistrar.carbonModifiers([]), 0)
        XCTAssertEqual(CarbonHotKeyRegistrar.carbonModifiers([.command, .option, .shift]),
                       UInt32(cmdKey | optionKey | shiftKey))
        XCTAssertEqual(CarbonHotKeyRegistrar.carbonModifiers([.control, .function]), UInt32(controlKey))
    }
}
