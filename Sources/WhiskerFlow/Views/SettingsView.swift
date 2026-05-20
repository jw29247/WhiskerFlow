import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @Binding var showMenuBarExtra: Bool

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show WhiskerFlow in the menu bar", isOn: $showMenuBarExtra)
            }

            Section("Whisper CLI") {
                TextField("Command", text: $appState.whisperCommand)
                TextField("Arguments", text: $appState.whisperArguments)
                Text("Default is Whisper base for fast, more accurate dictation. Use {audio} for the recording path and {output} for a temporary transcript output folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(width: 560)
    }
}
