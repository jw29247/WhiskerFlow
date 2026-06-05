import SwiftUI
import WhiskerFlowCore

struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            engineTab
                .tabItem { Label("Engine", systemImage: "cpu") }
            vocabularyTab
                .tabItem { Label("Vocabulary", systemImage: "character.book.closed") }
            advancedTab
                .tabItem { Label("Advanced", systemImage: "terminal") }
        }
        .frame(width: 560, height: 460)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Recording") {
                Picker("Hotkey", selection: $appState.settings.hotkey) {
                    ForEach(HotkeyTrigger.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: appState.settings.hotkey) { _, _ in appState.reloadHotkey() }

                Picker("Mode", selection: $appState.settings.recordingMode) {
                    ForEach(RecordingMode.allCases) { Text($0.displayName).tag($0) }
                }

                Picker("Microphone", selection: $appState.settings.selectedDeviceID) {
                    ForEach(appState.devices) { Text($0.name).tag($0.id) }
                }
                Button("Refresh microphones") { appState.refreshDevices() }
            }

            Section("Output") {
                Picker("When done", selection: $appState.settings.delivery) {
                    ForEach(DeliveryMode.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Play sound cues", isOn: $appState.settings.playSounds)
            }

            Section("App") {
                Toggle("Show in menu bar", isOn: $appState.settings.showMenuBarExtra)
                Toggle("Show Dock icon", isOn: $appState.settings.showDockIcon)
                Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Engine

    private var engineTab: some View {
        Form {
            Section("Transcription engine") {
                Picker("Engine", selection: $appState.settings.engine) {
                    ForEach(TranscriptionEngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: appState.settings.engine) { _, _ in appState.warmUpEngine() }
                Text(appState.settings.engine.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.settings.engine != .appleSpeech {
                    Picker("Model", selection: $appState.settings.model) {
                        ForEach(WhisperModel.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: appState.settings.model) { _, _ in appState.warmUpEngine() }
                }

                Picker("Language", selection: $appState.settings.language) {
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                }

                Toggle("Fall back to Apple Speech if the model is unavailable",
                       isOn: $appState.settings.allowAppleFallback)
            }

            Section("Model status") {
                HStack {
                    modelStatusView
                    Spacer()
                    Button("Reload") { appState.warmUpEngine() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch appState.modelState {
        case .unloaded:
            Label("Not loaded", systemImage: "circle")
        case .preparing:
            Label("Preparing \(appState.settings.model.displayName)…", systemImage: "arrow.down.circle")
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    // MARK: - Vocabulary

    private var vocabularyTab: some View {
        Form {
            Section {
                Text("Replace recognized words automatically — e.g. fix names or jargon Whisper gets wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Replacements") {
                ForEach($appState.settings.vocabulary.rules) { $rule in
                    HStack {
                        TextField("Heard", text: $rule.find)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Replace with", text: $rule.replaceWith)
                    }
                }
                .onDelete { appState.settings.vocabulary.rules.remove(atOffsets: $0) }

                Button {
                    appState.settings.vocabulary.rules.append(VocabularyRule(find: "", replaceWith: ""))
                } label: {
                    Label("Add replacement", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        Form {
            Section("Whisper CLI") {
                Text("Only used when the engine is set to Whisper CLI. Use {audio} for the recording path and {output} for a temporary output folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Command", text: $appState.settings.whisperCommand)
                TextField("Arguments", text: $appState.settings.whisperArguments)
            }
        }
        .formStyle(.grouped)
    }

    static let languages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("ru", "Russian")
    ]
}
