import Foundation

/// Which key activates push-to-talk.
public enum HotkeyTrigger: String, Codable, CaseIterable, Sendable, Identifiable {
    case fn
    case rightCommand
    case rightOption
    case f5

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fn: return "fn (Globe)"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .f5: return "F5"
        }
    }
}
