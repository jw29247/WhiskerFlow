import Foundation

/// Device-independent modifier flags. Raw values intentionally match
/// `NSEvent.ModifierFlags` so the AppKit layer can convert without a lookup.
public struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 17)
    public static let control = KeyModifiers(rawValue: 1 << 18)
    public static let option = KeyModifiers(rawValue: 1 << 19)
    public static let command = KeyModifiers(rawValue: 1 << 20)
    public static let function = KeyModifiers(rawValue: 1 << 23)

    /// The modifiers that matter when matching a key combo. `.function` is
    /// deliberately excluded: macOS sets it automatically for F-keys and arrows,
    /// which would otherwise make a plain "F12" combo impossible to match.
    public static let comboMask: KeyModifiers = [.shift, .control, .option, .command]

    /// Every modifier the recorder recognises, including `.function`.
    public static let all: KeyModifiers = [.shift, .control, .option, .command, .function]

    /// Symbols in canonical macOS menu order (⌃⌥⇧⌘).
    var symbols: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// An arbitrary push-to-talk hotkey: either a regular key (optionally with
/// modifiers held) or a single modifier key tapped on its own.
///
/// `keyCode` is a virtual key code. When `isModifierOnly` is true the key code
/// identifies a specific modifier key (so left/right ⌘ are distinguishable) and
/// `modifierFlags` holds the single flag that key produces.
public struct KeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifierFlags: UInt
    public var isModifierOnly: Bool

    public init(keyCode: UInt16, modifiers: KeyModifiers = [], isModifierOnly: Bool = false) {
        self.keyCode = keyCode
        self.modifierFlags = modifiers.rawValue
        self.isModifierOnly = isModifierOnly
    }

    public var modifiers: KeyModifiers { KeyModifiers(rawValue: modifierFlags) }

    /// A sensible standalone default for first-time custom selection: F12, which
    /// rarely conflicts with system or app shortcuts.
    public static let `default` = KeyCombo(keyCode: 111)

    /// Whether this combo is safe to use as a global push-to-talk trigger.
    /// A bare key with no modifiers (e.g. a plain letter or Space) would fire on
    /// every keystroke system-wide, so only function keys may stand alone.
    public var isUsableAsGlobalHotkey: Bool {
        if isModifierOnly { return true }
        if !modifiers.intersection(.comboMask).isEmpty { return true }
        return Self.functionKeyCodes.contains(keyCode)
    }

    /// Function-row keys (F1–F20), which are safe to trigger without a modifier.
    public static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90
    ]

    public var displayName: String {
        if isModifierOnly {
            return Self.modifierKeyName(for: keyCode) ?? "Key \(keyCode)"
        }
        let key = Self.keyName(for: keyCode) ?? "Key \(keyCode)"
        return modifiers.symbols + key
    }

    // MARK: - Key code tables

    /// Modifier keys, mapped to the flag they produce. Used both for display and
    /// by the recorder/monitor to relate a key code to its modifier flag.
    public static let modifierKeys: [UInt16: (name: String, flag: KeyModifiers)] = [
        54: ("Right ⌘", .command),
        55: ("⌘", .command),
        56: ("⇧", .shift),
        57: ("⇪ Caps Lock", []),
        58: ("⌥", .option),
        59: ("⌃", .control),
        60: ("Right ⇧", .shift),
        61: ("Right ⌥", .option),
        62: ("Right ⌃", .control),
        63: ("fn (Globe)", .function)
    ]

    static func modifierKeyName(for keyCode: UInt16) -> String? {
        modifierKeys[keyCode]?.name
    }

    /// Human-readable label for a non-modifier key code.
    static func keyName(for keyCode: UInt16) -> String? {
        keyNames[keyCode]
    }

    private static let keyNames: [UInt16: String] = [
        // Letters
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        // Digits
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
        // Punctuation
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 50: "`",
        // Whitespace / editing
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 117: "⌦", 114: "Help",
        // Navigation
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
        // Keypad
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
        86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
        91: "Keypad 8", 92: "Keypad 9", 65: "Keypad .", 67: "Keypad *",
        69: "Keypad +", 75: "Keypad /", 78: "Keypad -", 81: "Keypad =",
        76: "Keypad ↩"
    ]
}
