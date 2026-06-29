import XCTest
@testable import WhiskerFlowCore

final class KeyComboTests: XCTestCase {
    func testKeyComboDisplayNameComposesModifiersInCanonicalOrder() {
        // ⌥Space
        let optSpace = KeyCombo(keyCode: 49, modifiers: .option)
        XCTAssertEqual(optSpace.displayName, "⌥Space")

        // Canonical order is ⌃⌥⇧⌘ regardless of insertion order.
        let chord = KeyCombo(keyCode: 2, modifiers: [.command, .shift, .control, .option])
        XCTAssertEqual(chord.displayName, "⌃⌥⇧⌘D")
    }

    func testPlainKeyHasNoModifierSymbols() {
        XCTAssertEqual(KeyCombo(keyCode: 111).displayName, "F12")
        XCTAssertEqual(KeyCombo(keyCode: 49).displayName, "Space")
    }

    func testModifierOnlyDisplayNameUsesSideSpecificLabel() {
        let rightOption = KeyCombo(keyCode: 61, modifiers: .option, isModifierOnly: true)
        XCTAssertEqual(rightOption.displayName, "Right ⌥")

        let fn = KeyCombo(keyCode: 63, modifiers: .function, isModifierOnly: true)
        XCTAssertEqual(fn.displayName, "fn (Globe)")
    }

    func testUnknownKeyCodeFallsBackGracefully() {
        XCTAssertEqual(KeyCombo(keyCode: 9999).displayName, "Key 9999")
    }

    func testRoundTripsThroughCodable() throws {
        let combo = KeyCombo(keyCode: 2, modifiers: [.command, .option], isModifierOnly: false)
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: data)
        XCTAssertEqual(decoded, combo)
        XCTAssertEqual(decoded.modifiers, [.command, .option])
    }

    func testDefaultIsAStandaloneKey() {
        XCTAssertFalse(KeyCombo.default.isModifierOnly)
        XCTAssertTrue(KeyCombo.default.modifiers.isEmpty)
        XCTAssertEqual(KeyCombo.default.displayName, "F12")
    }

    func testComboMaskExcludesFunctionFlag() {
        // F-keys/arrows set .function automatically; it must not be part of the
        // mask the monitor compares, or plain F-key combos could never match.
        XCTAssertFalse(KeyModifiers.comboMask.contains(.function))
        XCTAssertTrue(KeyModifiers.comboMask.contains(.command))
    }

    func testPresetCombosMatchLegacyTriggers() {
        XCTAssertEqual(HotkeyTrigger.fn.presetCombo,
                       KeyCombo(keyCode: 63, modifiers: .function, isModifierOnly: true))
        XCTAssertEqual(HotkeyTrigger.rightCommand.presetCombo,
                       KeyCombo(keyCode: 54, modifiers: .command, isModifierOnly: true))
        XCTAssertEqual(HotkeyTrigger.rightOption.presetCombo,
                       KeyCombo(keyCode: 61, modifiers: .option, isModifierOnly: true))
        XCTAssertEqual(HotkeyTrigger.f5.presetCombo, KeyCombo(keyCode: 96))
        XCTAssertNil(HotkeyTrigger.custom.presetCombo)
    }
}
