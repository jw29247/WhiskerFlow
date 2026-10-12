import Foundation

/// macOS's "Press 🌐 key to" setting (Keyboard settings), stored as
/// `AppleFnUsageType` in the `com.apple.HIToolbox` defaults domain. Anything
/// but Do Nothing makes the Globe key act on its own when it is used as the
/// dictation shortcut.
public enum GlobeKeyUsage: Equatable, Sendable {
    case doNothing
    case changeInputSource
    case showEmojiAndSymbols
    case startDictation
    /// No value written yet: macOS applies its own default, which does act.
    case systemDefault
    case unrecognized(Int)

    public static let defaultsDomain = "com.apple.HIToolbox"
    public static let defaultsKey = "AppleFnUsageType"

    public init(storedValue: Int?) {
        switch storedValue {
        case nil: self = .systemDefault
        case 0: self = .doNothing
        case 1: self = .changeInputSource
        case 2: self = .showEmojiAndSymbols
        case 3: self = .startDictation
        case let value?: self = .unrecognized(value)
        }
    }

    /// Reads the current value from the user's preferences.
    public static func current() -> GlobeKeyUsage {
        let value = CFPreferencesCopyAppValue(defaultsKey as CFString, defaultsDomain as CFString)
        return GlobeKeyUsage(storedValue: (value as? NSNumber)?.intValue)
    }

    public var conflictsWithShortcut: Bool { self != .doNothing }

    public var displayName: String {
        switch self {
        case .doNothing: return "Do Nothing"
        case .changeInputSource: return "Change Input Source"
        case .showEmojiAndSymbols: return "Show Emoji & Symbols"
        case .startDictation: return "Start Dictation"
        case .systemDefault: return "the macOS default"
        case .unrecognized: return "another action"
        }
    }

    public var conflictExplanation: String? {
        guard conflictsWithShortcut else { return nil }
        let effect: String
        switch self {
        case .changeInputSource: effect = "switch your keyboard layout"
        case .showEmojiAndSymbols: effect = "open the emoji picker"
        case .startDictation: effect = "start Apple’s dictation"
        default: effect = "do something of its own"
        }
        return "Your 🌐 key is set to \(displayName), so pressing it will also \(effect). In Keyboard settings, set “Press 🌐 key to” to Do Nothing."
    }
}
