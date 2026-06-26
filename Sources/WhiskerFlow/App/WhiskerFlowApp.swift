import SwiftUI

@main
struct WhiskerFlowApp: App {
    @State private var appState = AppState()
    @StateObject private var updaterService = UpdaterService()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(appState: appState)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updaterService: updaterService)
            }
            CommandGroup(after: .newItem) {
                Button("Copy Selected Transcript") {
                    if let text = appState.selectedRecord?.text, !text.isEmpty {
                        appState.copy(text)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(appState.selectedRecord?.text.isEmpty ?? true)
            }
        }

        Settings {
            SettingsView(appState: appState, updaterService: updaterService)
        }

        MenuBarExtra(
            "WhiskerFlow",
            systemImage: appState.isRecording ? "waveform.circle.fill" : "waveform.circle",
            isInserted: $appState.settings.showMenuBarExtra
        ) {
            MenuBarView(appState: appState, updaterService: updaterService)
        }
        .menuBarExtraStyle(.window)
    }
}
