import Foundation
import WhiskerFlowCore

/// Choices setup no longer asks about. Each comes from the Mac and stays
/// changeable in Settings.
public enum OnboardingDefaults {
    /// The shortcut setup falls back to when fn can't be kept for dictation:
    /// the next key in the app's own list, and one that types nothing.
    public static let fallbackShortcut: HotkeyTrigger = .rightCommand

    /// The dictation shortcut to switch to, or nil to keep the current one.
    ///
    /// fn is the default. While WhiskerFlow runs it sets the Globe key to Do
    /// Nothing so fn is free for dictation (`GlobeKeyShortcutOverride`). When
    /// macOS refuses that change, holding fn would also switch layouts or
    /// open the emoji picker, so a person who never picked a shortcut moves to
    /// `fallbackShortcut`. A shortcut the person chose is never replaced.
    public static func shortcut(
        current: HotkeyTrigger,
        personChoseShortcut: Bool,
        fnReservedForDictation: Bool
    ) -> HotkeyTrigger? {
        guard !personChoseShortcut, current == .fn, !fnReservedForDictation else { return nil }
        return fallbackShortcut
    }

    /// The dictation language for a new install: the first of the Mac's
    /// preferred languages that WhiskerFlow can write, else English. An
    /// existing install keeps what it has (English when it never chose).
    public static func initialLanguage(isFirstLaunch: Bool, preferredLanguages: [String]) -> String {
        guard isFirstLaunch else { return "en" }
        return DictationLanguageCatalog.suggested(preferredLanguages: preferredLanguages)
    }
}
