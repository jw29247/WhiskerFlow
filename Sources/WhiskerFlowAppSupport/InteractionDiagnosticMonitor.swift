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

@MainActor
final class InteractionDiagnosticMonitor {
    static let shared = InteractionDiagnosticMonitor()
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var activationObservers: [NSObjectProtocol] = []

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
        let source = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = source
        RunLoop.main.add(source, forMode: .common)
        refresh()
    }

    private func refresh() {
        MainThreadHealthMonitor.shared.updateInteraction(InteractionDiagnosticContext(
            appActive: NSApp?.isActive ?? false,
            visibleWindows: NSApp?.windows.filter { $0.isVisible && $0.canBecomeMain }.count ?? 0,
            accessibilityTrusted: AXIsProcessTrusted(),
            secureInput: IsSecureEventInputEnabled(),
            globeKeyUsage: .current()
        ))
    }
}
