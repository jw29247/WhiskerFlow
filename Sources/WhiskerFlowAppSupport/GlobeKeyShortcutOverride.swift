import Foundation
import Logging
import WhiskerFlowCore

@MainActor
public final class GlobeKeyShortcutOverride {
    private struct PreviousAction: Codable {
        let value: Int?
    }

    private let defaults: UserDefaults
    private let preferencesDomain: String
    private let backupKey = "hotkey.globe.previousAction"
    private let logger = Logging.Logger(label: "agency.thatworks.WhiskerFlow.DictationLifecycle")

    public convenience init() {
        self.init(defaults: .standard, preferencesDomain: GlobeKeyUsage.defaultsDomain)
    }

    init(defaults: UserDefaults, preferencesDomain: String) {
        self.defaults = defaults
        self.preferencesDomain = preferencesDomain
    }

    public func update(shortcut: KeyCombo) -> Bool {
        guard shortcut == HotkeyTrigger.fn.presetCombo else { return restore() }
        guard CFPreferencesAppSynchronize(preferencesDomain as CFString) else { return false }
        let current = read()
        guard current != 0 else { return true }

        // Persist before changing macOS so a crash or update cannot lose the
        // user's original action. A later external choice replaces the backup.
        guard let backup = try? JSONEncoder().encode(PreviousAction(value: current)) else { return false }
        defaults.set(backup, forKey: backupKey)
        guard defaults.synchronize(), write(0) else { return false }
        logger.info("Reserved Fn for dictation", metadata: [
            "event": "globe_key_override_applied",
            "globe_key_action": "\(GlobeKeyUsage(storedValue: current).diagnosticValue)"
        ])
        return true
    }

    public func restore() -> Bool {
        guard let data = defaults.data(forKey: backupKey),
              let previous = try? JSONDecoder().decode(PreviousAction.self, from: data) else { return true }
        guard CFPreferencesAppSynchronize(preferencesDomain as CFString) else { return false }
        // Another application or Keyboard Settings may have changed the action.
        // Restore only the value this override still owns.
        if read() == 0 {
            guard write(previous.value) else { return false }
            logger.info("Restored the macOS Globe-key action", metadata: [
                "event": "globe_key_override_restored",
                "globe_key_action": "\(GlobeKeyUsage(storedValue: previous.value).diagnosticValue)"
            ])
        }
        defaults.removeObject(forKey: backupKey)
        return defaults.synchronize()
    }

    private func read() -> Int? {
        (CFPreferencesCopyAppValue(GlobeKeyUsage.defaultsKey as CFString, preferencesDomain as CFString) as? NSNumber)?.intValue
    }

    private func write(_ value: Int?) -> Bool {
        CFPreferencesSetAppValue(GlobeKeyUsage.defaultsKey as CFString,
                                 value.map { NSNumber(value: $0) }, preferencesDomain as CFString)
        return CFPreferencesAppSynchronize(preferencesDomain as CFString) && read() == value
    }
}
