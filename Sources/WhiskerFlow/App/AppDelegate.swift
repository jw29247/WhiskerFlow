import AppKit
import WhiskerFlowAppSupport

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `@NSApplicationDelegateAdaptor` builds the delegate itself, so `WhiskerFlowApp.init`
    /// hands the state over here for the delegate to pick up at launch.
    static var launchAppState: AppState?

    private var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = Self.launchAppState
        // Startup publishes @Observable changes that reach List rows and the
        // activation policy. Running that inside a launch callback can re-enter
        // AppKit while scene restoration is still laying out, so defer one
        // main-queue turn — never call `start()` synchronously from here.
        DispatchQueue.main.async { [weak self] in
            guard let appState = self?.appState else { return }
            appState.start()
            appState.applyActivationPolicy()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState?.refreshPermissionsAfterActivation()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState, appState.hasPendingWork else {
            appState?.stopMonitors()
            Observability.shutdown(timeout: 2)
            return .terminateNow
        }
        // `shutdown()` is bounded, so the reply always arrives.
        Task { @MainActor in
            await appState.shutdown()
            Observability.shutdown(timeout: 2)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
