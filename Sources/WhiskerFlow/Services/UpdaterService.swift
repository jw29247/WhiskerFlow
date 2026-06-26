import Combine
import Sparkle
import SwiftUI

/// Owns the Sparkle updater for the whole app lifetime.
///
/// `SPUStandardUpdaterController` wires up the standard update UI and the
/// scheduled background checks driven by the `SU*` keys in `Info.plist`
/// (`SUFeedURL`, `SUPublicEDKey`, `SUScheduledCheckInterval`). This is the only
/// file that imports Sparkle — the rest of the app talks to `UpdaterService`,
/// so the dependency stays contained.
@MainActor
final class UpdaterService: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private var updater: SPUUpdater { controller.updater }

    /// False while a check can't start (e.g. one is already running) — used to
    /// disable the "Check for Updates…" button.
    @Published private(set) var canCheckForUpdates = false

    /// Mirrors Sparkle's stored preference; writing flips the real setting.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    init() {
        // startingUpdater: true begins scheduled checks immediately. Nil delegates
        // keep Sparkle's standard behavior, including the first-run prompt asking
        // permission to check automatically.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Trigger a user-initiated check (shows progress + "you're up to date" UI).
    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

/// "Check for Updates…" button that disables itself while a check can't run.
/// Reusable in both the main menu (`Commands`) and the menu-bar popover.
struct CheckForUpdatesButton: View {
    @ObservedObject var updaterService: UpdaterService

    var body: some View {
        Button("Check for Updates…") { updaterService.checkForUpdates() }
            .disabled(!updaterService.canCheckForUpdates)
    }
}
