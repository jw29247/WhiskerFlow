import XCTest
@testable import WhiskerFlowCore

/// Records every call and refuses whatever `refuse` says, standing in for
/// Carbon so no real hot key is ever registered.
@MainActor
final class FakeShortcutRegistrar: ShortcutRegistrar {
    var active: [RegisteredShortcut: KeyCombo] = [:]
    var calls: [String] = []
    var refuse: (RegisteredShortcut, KeyCombo) -> Bool = { _, _ in false }

    func register(_ shortcut: RegisteredShortcut, combo: KeyCombo) -> Bool {
        calls.append("register \(shortcut)")
        XCTAssertNil(active[shortcut], "registered twice without unregistering")
        guard !refuse(shortcut, combo) else { return false }
        active[shortcut] = combo
        return true
    }

    func unregister(_ shortcut: RegisteredShortcut) {
        calls.append("unregister \(shortcut)")
        XCTAssertNotNil(active[shortcut], "unregistered something not registered")
        active[shortcut] = nil
    }
}

@MainActor
final class RegisteredShortcutControllerTests: XCTestCase {
    private let fn = HotkeyTrigger.fn.presetCombo!
    private let rightCommand = HotkeyTrigger.rightCommand.presetCombo!
    private let f5 = HotkeyTrigger.f5.presetCombo!
    private let ctrlOptSpace = KeyCombo(keyCode: 49, modifiers: [.control, .option])
    private let fnSpace = KeyCombo(keyCode: 49, modifiers: [.function])
    private let meeting = KeyCombo(keyCode: 15, modifiers: [.command, .option, .shift])
    private let escape = KeyCombo(keyCode: 53)

    private func make(_ dictation: KeyCombo, registrar: FakeShortcutRegistrar? = nil)
        -> (RegisteredShortcutController, FakeShortcutRegistrar) {
        let registrar = registrar ?? FakeShortcutRegistrar()
        return (RegisteredShortcutController(registrar: registrar, dictationCombo: dictation, meetingCombo: meeting), registrar)
    }

    // MARK: - What is registered for each kind of shortcut

    func testNothingIsRegisteredBeforeStart() {
        let (_, registrar) = make(f5)
        XCTAssertTrue(registrar.calls.isEmpty)
    }

    func testFnGlobeIsNeverRegisteredButMeetingIs() {
        let (controller, registrar) = make(fn)
        controller.start()
        XCTAssertEqual(registrar.active, [.meeting: meeting])
        XCTAssertFalse(controller.isRegistered(.dictation))
    }

    func testOtherModifierOnlyShortcutIsNeverRegistered() {
        let (controller, registrar) = make(rightCommand)
        controller.start()
        XCTAssertEqual(registrar.active, [.meeting: meeting])
    }

    func testCombinationWithFnIsNeverRegistered() {
        XCTAssertFalse(RegisteredShortcutController.canRegister(fnSpace))
        let (controller, registrar) = make(fnSpace)
        controller.start()
        XCTAssertEqual(registrar.active, [.meeting: meeting])
    }

    func testFunctionKeyIsRegistered() {
        let (controller, registrar) = make(f5)
        controller.start()
        XCTAssertEqual(registrar.active, [.dictation: f5, .meeting: meeting])
        XCTAssertTrue(controller.isRegistered(.dictation))
    }

    func testKeyCombinationIsRegistered() {
        let (controller, registrar) = make(ctrlOptSpace)
        controller.start()
        XCTAssertEqual(registrar.active, [.dictation: ctrlOptSpace, .meeting: meeting])
    }

    func testDictationOwnsTheMeetingComboWhenTheyAreTheSame() {
        let (controller, registrar) = make(meeting)
        controller.start()
        XCTAssertEqual(registrar.active, [.dictation: meeting])
    }

    func testStopUnregistersEverything() {
        let (controller, registrar) = make(f5)
        controller.start()
        controller.setDiscardWindowOpen(true)
        controller.stop()
        XCTAssertTrue(registrar.active.isEmpty)
        XCTAssertTrue(controller.registeredCombos.isEmpty)
    }

    // MARK: - Fall-back

    func testRefusedDictationShortcutFallsBackAndIsNotRetriedForTheSameCombo() {
        let registrar = FakeShortcutRegistrar()
        registrar.refuse = { shortcut, _ in shortcut == .dictation }
        let (controller, _) = make(ctrlOptSpace, registrar: registrar)
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.start()
        XCTAssertFalse(controller.isRegistered(.dictation), "the observing monitors keep the shortcut")
        XCTAssertEqual(registrar.active, [.meeting: meeting])
        XCTAssertEqual(changes, 1)

        registrar.calls = []
        controller.setDiscardWindowOpen(true)
        controller.setDiscardWindowOpen(false)
        XCTAssertFalse(registrar.calls.contains("register dictation"), "not retried on unrelated changes")
    }

    func testRefusedShortcutIsRetriedAfterSuspensionAndForANewCombo() {
        let registrar = FakeShortcutRegistrar()
        var refusing = true
        registrar.refuse = { shortcut, _ in shortcut == .dictation && refusing }
        let (controller, _) = make(ctrlOptSpace, registrar: registrar)
        controller.start()
        refusing = false
        controller.setSuspended(true)
        controller.setSuspended(false)
        XCTAssertTrue(controller.isRegistered(.dictation))

        refusing = true
        controller.setDictationCombo(f5)
        XCTAssertFalse(controller.isRegistered(.dictation))
        refusing = false
        controller.setDictationCombo(ctrlOptSpace)
        XCTAssertTrue(controller.isRegistered(.dictation))
    }

    func testRefusedEscapeLeavesTheObservedEscape() {
        let registrar = FakeShortcutRegistrar()
        registrar.refuse = { shortcut, _ in shortcut == .discard }
        let (controller, _) = make(fn, registrar: registrar)
        controller.start()
        controller.setDiscardWindowOpen(true)
        XCTAssertFalse(controller.isRegistered(.discard))
        XCTAssertNil(controller.handle(.discard, pressed: true))
    }

    // MARK: - Pressed and released

    func testDictationPressAndReleaseMapToTransitions() {
        let (controller, _) = make(f5)
        controller.start()
        XCTAssertEqual(controller.handle(.dictation, pressed: true), .dictation(pressed: true))
        XCTAssertEqual(controller.handle(.dictation, pressed: false), .dictation(pressed: false))
    }

    func testRepeatedPressWhileHeldActsOnce() {
        let (controller, _) = make(f5)
        controller.start()
        XCTAssertEqual(controller.handle(.dictation, pressed: true), .dictation(pressed: true))
        XCTAssertNil(controller.handle(.dictation, pressed: true))
        XCTAssertNil(controller.handle(.dictation, pressed: true))
        XCTAssertEqual(controller.handle(.dictation, pressed: false), .dictation(pressed: false))
        XCTAssertNil(controller.handle(.dictation, pressed: false), "a stray release does nothing")
    }

    func testMeetingTogglesOncePerPressEvenIfThePressRepeats() {
        let (controller, _) = make(fn)
        controller.start()
        XCTAssertEqual(controller.handle(.meeting, pressed: true), .toggleMeeting)
        XCTAssertNil(controller.handle(.meeting, pressed: true))
        XCTAssertNil(controller.handle(.meeting, pressed: false))
        XCTAssertEqual(controller.handle(.meeting, pressed: true), .toggleMeeting)
    }

    func testEventsForAShortcutNoLongerRegisteredAreIgnored() {
        let (controller, _) = make(f5)
        controller.start()
        controller.setSuspended(true)
        XCTAssertNil(controller.handle(.dictation, pressed: true))
        XCTAssertNil(controller.handle(.meeting, pressed: true))
        XCTAssertNil(controller.handle(.discard, pressed: true))
    }

    /// The matcher fed only by the registered hot key gives exactly the
    /// transitions the observing path gives. Hold reads them as start/stop;
    /// toggle starts on the first press and stops on the second.
    func testHoldAndToggleSequencesThroughTheMatcher() {
        let (controller, _) = make(ctrlOptSpace)
        controller.start()
        var matcher = HotkeyMatcher(combo: ctrlOptSpace)
        var transitions: [Bool] = []
        func feed(_ pressed: Bool) {
            guard case .dictation(let pressed)? = controller.handle(.dictation, pressed: pressed),
                  let transition = matcher.handleRegisteredHotKey(pressed: pressed) else { return }
            transitions.append(transition)
        }
        feed(true); feed(true); feed(false) // hold, with a repeated press
        XCTAssertEqual(transitions, [true, false])
        feed(true); feed(false); feed(true); feed(false) // toggle: two taps
        XCTAssertEqual(transitions, [true, false, true, false, true, false])
    }

    /// Releasing a required modifier first still ends the press once: the
    /// observed modifier change releases, and the hot key's release is a no-op.
    func testModifierReleaseThenHotKeyReleaseCountsOnce() {
        var matcher = HotkeyMatcher(combo: ctrlOptSpace)
        XCTAssertEqual(matcher.handleRegisteredHotKey(pressed: true), true)
        XCTAssertEqual(matcher.handleFlags(keyCode: 59, modifiers: [.option]), false)
        XCTAssertNil(matcher.handleRegisteredHotKey(pressed: false))
    }

    func testModifierOnlyMatcherIgnoresRegisteredEvents() {
        var matcher = HotkeyMatcher(combo: fn)
        XCTAssertNil(matcher.handleRegisteredHotKey(pressed: true))
        XCTAssertFalse(matcher.isPressed)
    }

    // MARK: - Esc window

    func testEscapeIsRegisteredOnlyWhileTheWindowIsOpen() {
        let (controller, registrar) = make(fn)
        controller.start()
        XCTAssertNil(registrar.active[.discard])
        controller.setDiscardWindowOpen(true)
        XCTAssertEqual(registrar.active[.discard], escape)
        XCTAssertEqual(controller.handle(.discard, pressed: true), .discard)
        controller.setDiscardWindowOpen(false)
        XCTAssertNil(registrar.active[.discard])
        XCTAssertNil(controller.handle(.discard, pressed: true))
    }

    func testEscapeIsNotRegisteredWhileSuspended() {
        let (controller, registrar) = make(f5)
        controller.start()
        controller.setDiscardWindowOpen(true)
        controller.setSuspended(true)
        XCTAssertTrue(registrar.active.isEmpty)
        controller.setSuspended(false)
        XCTAssertEqual(registrar.active[.discard], escape)
    }

    // MARK: - Suspension and changes

    func testSuspensionRemovesAllAndRestoresAfterwards() {
        let (controller, registrar) = make(ctrlOptSpace)
        var changes = 0
        controller.onChange = { changes += 1 }
        controller.start()
        controller.setSuspended(true)
        XCTAssertTrue(registrar.active.isEmpty)
        controller.setSuspended(false)
        XCTAssertEqual(registrar.active, [.dictation: ctrlOptSpace, .meeting: meeting])
        XCTAssertEqual(changes, 3)
    }

    func testChangingTheShortcutReregisters() {
        let (controller, registrar) = make(ctrlOptSpace)
        controller.start()
        registrar.calls = []
        controller.setDictationCombo(f5)
        XCTAssertEqual(registrar.calls, ["unregister dictation", "register dictation"])
        XCTAssertEqual(registrar.active[.dictation], f5)

        controller.setDictationCombo(fn)
        XCTAssertNil(registrar.active[.dictation], "switching to fn/Globe unregisters")
        XCTAssertFalse(controller.isRegistered(.dictation))
    }

    func testChangingTheShortcutWhileSuspendedRegistersTheNewOneAfterwards() {
        let (controller, registrar) = make(ctrlOptSpace)
        controller.start()
        controller.setSuspended(true)
        controller.setDictationCombo(f5)
        XCTAssertTrue(registrar.active.isEmpty)
        controller.setSuspended(false)
        XCTAssertEqual(registrar.active[.dictation], f5)
    }

    // MARK: - Menu command and hot key arriving for one press

    func testSamePressFromBothSourcesTogglesOnce() {
        var gate = ShortcutPressDeduplicator()
        XCTAssertTrue(gate.shouldAct(eventTime: 100.000))
        XCTAssertFalse(gate.shouldAct(eventTime: 100.000), "the menu's key equivalent for the same press")
        XCTAssertFalse(gate.shouldAct(eventTime: 100.004))
        XCTAssertTrue(gate.shouldAct(eventTime: 102.0), "a later press")
    }

    func testMenuClickAlwaysActs() {
        var gate = ShortcutPressDeduplicator()
        XCTAssertTrue(gate.shouldAct(eventTime: 100))
        XCTAssertTrue(gate.shouldAct(eventTime: nil))
        XCTAssertTrue(gate.shouldAct(eventTime: nil))
    }
}
