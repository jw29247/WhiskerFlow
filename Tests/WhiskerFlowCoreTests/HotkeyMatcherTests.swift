import XCTest
@testable import WhiskerFlowCore

final class HotkeyMatcherTests: XCTestCase {
    // Virtual key codes used in the scenarios below.
    private let dKey: UInt16 = 2
    private let spaceKey: UInt16 = 49
    private let f12Key: UInt16 = 111
    private let rightCommand: UInt16 = 54
    private let leftCommand: UInt16 = 55

    // MARK: - Regular key combos

    func testPlainKeyPressAndRelease() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: f12Key))
        XCTAssertEqual(matcher.handleKey(keyCode: f12Key, modifiers: [], isKeyDown: true, isRepeat: false), true)
        XCTAssertEqual(matcher.handleKey(keyCode: f12Key, modifiers: [], isKeyDown: false, isRepeat: false), false)
    }

    func testRepeatsAreIgnored() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: f12Key))
        XCTAssertEqual(matcher.handleKey(keyCode: f12Key, modifiers: [], isKeyDown: true, isRepeat: false), true)
        XCTAssertNil(matcher.handleKey(keyCode: f12Key, modifiers: [], isKeyDown: true, isRepeat: true))
    }

    func testModifierComboRequiresExactModifiers() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: dKey, modifiers: .command))
        // ⌘⇧D must not fire a ⌘D trigger.
        XCTAssertNil(matcher.handleKey(keyCode: dKey, modifiers: [.command, .shift], isKeyDown: true, isRepeat: false))
        // ⌘D fires.
        XCTAssertEqual(matcher.handleKey(keyCode: dKey, modifiers: .command, isKeyDown: true, isRepeat: false), true)
    }

    /// Regression: macOS suppresses keyUp for ordinary keys while ⌘ is held, so
    /// the press must release when the Command modifier goes up.
    func testCommandComboReleasesViaModifierUpWhenKeyUpIsSuppressed() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: dKey, modifiers: .command))
        XCTAssertEqual(matcher.handleKey(keyCode: dKey, modifiers: .command, isKeyDown: true, isRepeat: false), true)
        // No keyUp arrives for D; the user lifts Command instead.
        XCTAssertEqual(matcher.handleFlags(keyCode: leftCommand, modifiers: []), false)
        XCTAssertFalse(matcher.isPressed)
    }

    func testHeldComboNotReleasedByUnrelatedModifier() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: spaceKey, modifiers: .option))
        XCTAssertEqual(matcher.handleKey(keyCode: spaceKey, modifiers: .option, isKeyDown: true, isRepeat: false), true)
        // Tapping Shift while ⌥Space is held must not release.
        XCTAssertNil(matcher.handleFlags(keyCode: 56, modifiers: [.option, .shift]))
        XCTAssertNil(matcher.handleFlags(keyCode: 56, modifiers: .option))
        // Releasing the required Option does release.
        XCTAssertEqual(matcher.handleFlags(keyCode: 58, modifiers: []), false)
    }

    func testPlainKeyNotReleasedByIncidentalModifier() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: f12Key))
        XCTAssertEqual(matcher.handleKey(keyCode: f12Key, modifiers: [], isKeyDown: true, isRepeat: false), true)
        // F12 has no required modifier, so a stray ⌘ press/release must not flip it.
        XCTAssertNil(matcher.handleFlags(keyCode: leftCommand, modifiers: .command))
        XCTAssertNil(matcher.handleFlags(keyCode: leftCommand, modifiers: []))
        XCTAssertTrue(matcher.isPressed)
    }

    // MARK: - Modifier-only combos

    func testModifierOnlyPressAndRelease() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: rightCommand, modifiers: .command, isModifierOnly: true))
        XCTAssertEqual(matcher.handleFlags(keyCode: rightCommand, modifiers: .command), true)
        XCTAssertEqual(matcher.handleFlags(keyCode: rightCommand, modifiers: []), false)
    }

    /// Regression: releasing the recorded modifier key while its mirror key still
    /// holds the shared flag must not leave the trigger stuck pressed.
    func testModifierOnlyReleasesWhenSharedFlagClearsViaMirrorKey() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: rightCommand, modifiers: .command, isModifierOnly: true))
        XCTAssertEqual(matcher.handleFlags(keyCode: rightCommand, modifiers: .command), true)
        // Left ⌘ is also pressed; the flag stays set, so no transition yet.
        XCTAssertNil(matcher.handleFlags(keyCode: leftCommand, modifiers: .command))
        // Both keys finally up — the mirror key's event clears the flag and releases.
        XCTAssertEqual(matcher.handleFlags(keyCode: leftCommand, modifiers: []), false)
        XCTAssertFalse(matcher.isPressed)
    }

    func testKeyEventsIgnoredForModifierOnlyCombo() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: rightCommand, modifiers: .command, isModifierOnly: true))
        XCTAssertNil(matcher.handleKey(keyCode: dKey, modifiers: .command, isKeyDown: true, isRepeat: false))
    }

    // MARK: - Lifecycle

    func testUpdateReleasesInFlightPress() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: f12Key))
        XCTAssertEqual(matcher.handleKey(keyCode: f12Key, modifiers: [], isKeyDown: true, isRepeat: false), true)
        XCTAssertEqual(matcher.update(combo: KeyCombo(keyCode: dKey, modifiers: .command)), false)
        XCTAssertNil(matcher.update(combo: KeyCombo(keyCode: dKey, modifiers: .command))) // no-op when unchanged
    }

    func testResetReleasesOnlyWhenPressed() {
        var matcher = HotkeyMatcher(combo: KeyCombo(keyCode: f12Key))
        XCTAssertNil(matcher.reset())
        _ = matcher.handleKey(keyCode: f12Key, modifiers: [], isKeyDown: true, isRepeat: false)
        XCTAssertEqual(matcher.reset(), false)
    }

    // MARK: - Global-hotkey safety

    func testBareKeyIsNotUsableButFunctionKeyAndCombosAre() {
        XCTAssertFalse(KeyCombo(keyCode: 2).isUsableAsGlobalHotkey)               // plain D
        XCTAssertFalse(KeyCombo(keyCode: 49).isUsableAsGlobalHotkey)              // plain Space
        XCTAssertTrue(KeyCombo(keyCode: 2, modifiers: .command).isUsableAsGlobalHotkey) // ⌘D
        XCTAssertTrue(KeyCombo(keyCode: 111).isUsableAsGlobalHotkey)             // F12
        XCTAssertTrue(KeyCombo(keyCode: 61, modifiers: .option, isModifierOnly: true).isUsableAsGlobalHotkey)
    }
}
