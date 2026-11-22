import AppKit
import ApplicationServices
import Carbon

struct InteractionDiagnosticContext: Equatable, Sendable {
    let appActive: Bool
    let visibleWindows: Int
    let accessibilityTrusted: Bool
    let secureInput: Bool
    let globeKeyUsage: GlobeKeyUsage

    var fields: [String: String] {
        ["app_active": String(appActive), "visible_windows": String(visibleWindows),
         "accessibility": String(accessibilityTrusted), "secure_input": String(secureInput),
         "globe_key_action": globeKeyUsage.diagnosticValue]
    }
}

/// Keeps the interaction context for stall rows current: on activation,
/// sleep and wake, an Accessibility grant change, and on a slow timer for the
/// rest (Secure Input, the Globe-key setting, visible windows).
@MainActor
final class InteractionDiagnosticMonitor {
    static let shared = InteractionDiagnosticMonitor()
    /// Was 5 s. Context older than this shows as `context_age_ms`.
    static let refreshInterval: TimeInterval = 30
    static let refreshTolerance: TimeInterval = 5
    private(set) var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var activationObservers: [NSObjectProtocol] = []
    private var accessibilityObserver: NSObjectProtocol?
    private let read: @MainActor () -> InteractionDiagnosticContext
    private let publish: (InteractionDiagnosticContext) -> Void

    init(read: @escaping @MainActor () -> InteractionDiagnosticContext = InteractionDiagnosticMonitor.currentContext,
         publish: @escaping (InteractionDiagnosticContext) -> Void = { MainThreadHealthMonitor.shared.updateInteraction($0) }) {
        self.read = read
        self.publish = publish
    }

    func start() {
        guard timer == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainThreadHealthMonitor.shared.setSleeping(sleeping)
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            activationObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        // Posted as the Accessibility switch is flipped; the trust database
        // is updated just after.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let source = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.tolerance = Self.refreshTolerance
        timer = source
        RunLoop.main.add(source, forMode: .common)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        activationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if let accessibilityObserver { DistributedNotificationCenter.default().removeObserver(accessibilityObserver) }
        workspaceObservers = []
        activationObservers = []
        accessibilityObserver = nil
    }

    private func refresh() {
        publish(read())
    }

    static func currentContext() -> InteractionDiagnosticContext {
        InteractionDiagnosticContext(
            appActive: NSApp?.isActive ?? false,
            visibleWindows: NSApp?.windows.filter { $0.isVisible && $0.canBecomeMain }.count ?? 0,
            accessibilityTrusted: AXIsProcessTrusted(),
            secureInput: IsSecureEventInputEnabled(),
            globeKeyUsage: .current()
        )
    }
}
