import AppKit
import Carbon
import CoreGraphics

/// Tells the user when another app's Secure Event Input hides the shortcut.
///
/// While any app has Secure Event Input on (a focused password field, a
/// terminal's Secure Keyboard Entry), macOS stops delivering its key events to
/// other processes, so the dictation shortcut silently does nothing.
///
/// Checking is a cheap local call, but it is still never done on a tight loop:
/// the state is read when WhiskerFlow becomes active and whenever a view that
/// shows the notice appears (`refresh()`), which is when the user looks for
/// why the shortcut did nothing. Only while the notice is showing does a slow
/// timer keep checking, so it clears on its own once Secure Input ends; the
/// timer stops as soon as it does.
@MainActor
public final class SecureInputMonitor {
    public static let notice = "Secure input is on in another app, so the shortcut is paused."
    /// How often the state is re-read while the notice is showing.
    public static let pollInterval: TimeInterval = 3

    public private(set) var isActive = false
    /// Whether the slow timer is running; true only while `isActive`.
    public var isPolling: Bool { poll != nil }

    private let probe: () -> Bool
    private let onChange: (Bool) -> Void
    private var poll: Timer?
    private var activationObserver: NSObjectProtocol?

    public init(probe: @escaping () -> Bool = SecureInputMonitor.isHeldByAnotherProcess,
                onChange: @escaping (Bool) -> Void) {
        self.probe = probe
        self.onChange = onChange
    }

    public func start() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    public func stop() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        poll?.invalidate()
        poll = nil
    }

    /// Re-read the state now.
    public func refresh() {
        let active = probe()
        if active != isActive {
            isActive = active
            onChange(active)
        }
        if active, poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else if !active {
            poll?.invalidate()
            poll = nil
        }
    }

    /// Secure Event Input is on and not held by WhiskerFlow itself (its own
    /// key events still reach it). The owner's PID is published in the
    /// session dictionary; when it is missing, any holder counts.
    public nonisolated static func isHeldByAnotherProcess() -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = (session["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value else { return true }
        return pid != ProcessInfo.processInfo.processIdentifier
    }
}
