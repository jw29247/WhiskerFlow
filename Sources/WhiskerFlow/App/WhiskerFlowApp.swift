import SwiftUI

@main
struct WhiskerFlowApp: App {
    @State private var appState = AppState()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 980, minHeight: 620)
                .task {
                    appState.start()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Paste Selected Transcript") {
                    if let text = appState.selectedRecord?.text, !text.isEmpty {
                        appState.paste(text)
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(appState.selectedRecord?.text.isEmpty ?? true)
            }
        }

        Settings {
            SettingsView(appState: appState, showMenuBarExtra: $showMenuBarExtra)
        }

        MenuBarExtra("WhiskerFlow", systemImage: appState.isRecording ? "waveform.circle.fill" : "waveform.circle", isInserted: $showMenuBarExtra) {
            VStack(alignment: .leading, spacing: 8) {
                Text(appState.statusMessage)
                    .font(.headline)
                Text("\(appState.retryQueue.count) queued retries")
                    .foregroundStyle(.secondary)
                Divider()
                Button("Open WhiskerFlow") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Quit WhiskerFlow") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(10)
        }
    }
}
