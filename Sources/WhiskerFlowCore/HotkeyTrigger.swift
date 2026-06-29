import Foundation

/// Which key activates push-to-talk.
public enum HotkeyTrigger: String, Codable, CaseIterable, Sendable, Identifiable {
    case fn
    case rightCommand
    case rightOption
    case f5
    /// A user-recorded key combination, stored separately in `AppSettings`.
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fn: return "fn (Globe)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .f5: return "F5"
        case .custom: return "Custom…"
        }
    }

    /// The fixed presets as a `KeyCombo`, so the monitor can treat every trigger
    /// uniformly. `.custom` has no intrinsic combo — its value lives in settings.
    public var presetCombo: KeyCombo? {
        switch self {
        case .fn: return KeyCombo(keyCode: 63, modifiers: .function, isModifierOnly: true)
        case .rightCommand: return KeyCombo(keyCode: 54, modifiers: .command, isModifierOnly: true)
        case .rightOption: return KeyCombo(keyCode: 61, modifiers: .option, isModifierOnly: true)
        case .f5: return KeyCombo(keyCode: 96)
        case .custom: return nil
        }
    }
}
