import SwiftUI
import WhiskerFlowAppSupport

@main
struct WhiskerFlowApp: App {
    @State private var appState: AppState
    #if DEBUG
    /// A local 2.0 candidate must not replace itself with the public 0.x feed.
    @StateObject private var updaterService = UpdaterService(startingUpdater: false)
    #else
    @StateObject private var updaterService = UpdaterService(startingUpdater: !UIPreview.isEnabled)
    #endif
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        if !UIPreview.isEnabled {
            Observability.start()
            DiagnosticsService.start()
        }
        let appState = UIPreview.makeAppState()
        _appState = State(initialValue: appState)
        AppDelegate.launchAppState = appState
    }

    var body: some Scene {
        WindowGroup(UIPreview.isEnabled ? "WhiskerFlow · UI Preview" : "WhiskerFlow", id: "main") {
            ContentView(appState: appState)
                .preferredColorScheme(UIPreview.colorScheme)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            TranscriptCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updaterService: updaterService)
            }
            CommandGroup(after: .newItem) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--verify-corrections") {
                    Button("Verify selection preview in TextEdit") { appState.verifySelectionPreview() }
                    Button("Verify correction paste in TextEdit") { appState.verifyCorrectionPaste() }
                        .keyboardShortcut("p", modifiers: [.command, .option, .shift])
                }
                #endif
                Button("Voice edit selection · hold ⌥⇧⌘E") { appState.assistant.capturePurpose = .selectionInstruction }
                Button("Quick voice capture · hold ⌥⇧⌘N") { appState.assistant.capturePurpose = .quickCapture }
                Button("Bookmark meeting · ⌥⇧⌘B") { appState.bookmarkMeeting() }.disabled(!appState.isMeetingCapturing)
                Button("Toggle Meeting Capture") {
                    appState.toggleMeetingCapture()
                }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            }
        }

        Settings {
            SettingsView(appState: appState, updaterService: updaterService)
                .preferredColorScheme(UIPreview.colorScheme)
        }

        MenuBarExtra(
            "WhiskerFlow",
            systemImage: appState.meetingStatus == .recording
                ? "record.circle.fill"
                : (appState.isRecording ? "waveform.circle.fill" : "waveform.circle"),
            isInserted: $appState.settings.showMenuBarExtra
        ) {
            MenuBarView(appState: appState, updaterService: updaterService)
        }
        .menuBarExtraStyle(.window)
    }
}
