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
        #if DEBUG
        if CommandLine.arguments.contains("--probe-native-meet") { MeetingSpeakerProbe.runAndExit() }
        if CommandLine.arguments.contains("--debug-window-snapshots") {
            DispatchQueue.main.async { DebugWindowSnapshot.install() }
        }
        #endif
        if !UIPreview.isEnabled {
            Observability.start()
            DiagnosticsService.start()
        }
        let appState = UIPreview.makeAppState()
        _appState = State(initialValue: appState)
        AppDelegate.launchAppState = appState
        UIPreview.scheduleOnboardingSnapshotsIfRequested()
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
            CommandGroup(replacing: .help) {
                RunSetupAgainButton(appState: appState)
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

        // Its own window, not a sheet: an attached sheet makes AppKit refuse to
        // quit (including at logout), and setup must survive a quit mid-way.
        Window("Set Up WhiskerFlow", id: OnboardingWindow.id) {
            OnboardingView(appState: appState)
                .preferredColorScheme(UIPreview.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView(appState: appState, updaterService: updaterService)
                .preferredColorScheme(UIPreview.colorScheme)
        }

        WhiskerFlowMenuBarScene(appState: appState, updaterService: updaterService)
    }
}

struct WhiskerFlowMenuBarScene: Scene {
    @Bindable var appState: AppState
    let updaterService: UpdaterService

    var body: some Scene {
        MenuBarExtra(isInserted: $appState.settings.showMenuBarExtra) {
            MenuBarView(appState: appState, updaterService: updaterService)
        } label: {
            WhiskerFlowMenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}

struct WhiskerFlowMenuBarLabel: View {
    let appState: AppState

    var body: some View {
        Label("WhiskerFlow", systemImage: appState.meetingStatus == .recording
            ? "record.circle.fill"
            : (appState.isRecording ? "waveform.circle.fill" : "waveform.circle"))
            .modifier(AtlasSignInPresenter(appState: appState))
    }
}
