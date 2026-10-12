#if DEBUG
import AppKit

/// Debug-only end-to-end driver: a local tool presses and releases the
/// dictation key by posting `agency.thatworks.WhiskerFlow.debug.dictation`
/// with "press" or "release" as the object, and the real recording, paste and
/// correction paths run. With `--debug-dictation-trigger` the global hotkey is
/// not installed, so the user's own key presses reach only the installed app.
/// Release builds do not contain this code.
@MainActor
enum DebugDictationTrigger {
    static let notificationName = Notification.Name("agency.thatworks.WhiskerFlow.debug.dictation")
    private static var observer: NSObjectProtocol?

    static var isEnabled: Bool { CommandLine.arguments.contains("--debug-dictation-trigger") }

    /// `--e2e-defaults-suite=<name>` keeps preferences apart from the installed app.
    nonisolated static var defaultsSuite: String? {
        CommandLine.arguments.first { $0.hasPrefix("--e2e-defaults-suite=") }
            .map { String($0.dropFirst("--e2e-defaults-suite=".count)) }
            .flatMap { $0.hasPrefix("agency.thatworks.WhiskerFlow.e2e") ? $0 : nil }
    }

    static func install(_ handler: @escaping @MainActor (Bool) -> Void) {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main
        ) { notification in
            guard let object = notification.object as? String, ["press", "release"].contains(object) else { return }
            MainActor.assumeIsolated { handler(object == "press") }
        }
    }
}
#endif
