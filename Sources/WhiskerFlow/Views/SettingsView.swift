import SwiftUI
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct SettingsView: View {
    @Bindable var appState: AppState
    @ObservedObject var updaterService: UpdaterService
    @State private var category: SettingsCategory = .dictation

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Settings").font(.system(size: 21, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 24)
                ForEach(SettingsCategory.allCases) { item in
                    Button { category = item } label: {
                        Label(item.rawValue, systemImage: item.symbol)
                            .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(category == item ? FlowStyle.accent : FlowStyle.ink)
                    .background(category == item ? FlowStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal, 12).frame(width: 155).background(.ultraThinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(category.rawValue).font(.system(size: 25, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 25).padding(.top, 25).padding(.bottom, 5)
                Group {
                    switch category {
                    case .dictation: dictationTab
                    case .text: vocabularyTab
                    case .meetings: Form { MeetingSetupView(appState: appState) }.formStyle(.grouped)
                    case .app: appTab
                    case .advanced: engineTab
                    }
                }
                if let error = appState.settings.persistenceError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                        .foregroundStyle(.orange).padding(20)
                }
            }.frame(maxWidth: .infinity).background(FlowStyle.canvas)
        }
        .frame(width: 760, height: 650)
        .foregroundStyle(FlowStyle.ink).tint(FlowStyle.accent)
    }

    private var dictationTab: some View {
        Form {
            Section("Recording") {
                Picker("Hotkey", selection: $appState.settings.hotkey) {
                    ForEach(HotkeyTrigger.allCases) { Text($0.displayName).tag($0) }
                }
                .onChange(of: appState.settings.hotkey) { _, _ in appState.reloadHotkey() }

                if appState.settings.hotkey == .custom {
                    LabeledContent("Shortcut") {
                        KeyRecorderView(
                            combo: $appState.settings.customHotkey,
                            onChange: { appState.reloadHotkey() },
                            onRecordingChange: { appState.setHotkeyCaptureActive($0) }
                        )
                    }
                }

                Picker("Mode", selection: $appState.settings.recordingMode) {
                    ForEach(RecordingMode.allCases) { Text($0.displayName).tag($0) }
                }

                Toggle("Live transcription", isOn: $appState.settings.liveTranscription)
                Text("Show text while you speak when using WhisperKit. Other engines transcribe after recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Microphone", selection: $appState.settings.selectedInputUID) {
                    Text("System Default").tag("system-default")
                    if appState.settings.selectedInputUID != "system-default",
                       !appState.devices.contains(where: { $0.uid == appState.settings.selectedInputUID }) {
                        Text("Preferred microphone (disconnected)")
                            .tag(appState.settings.selectedInputUID)
                    }
                    ForEach(appState.devices) { Text($0.name).tag($0.uid) }
                }
                .disabled(appState.microphoneControlsLocked)
                Button("Refresh microphones") { appState.refreshDevices() }
                    .disabled(appState.microphoneControlsLocked)
            }

            Section("Language") {
                Picker("Language", selection: $appState.settings.language) {
                    ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .onChange(of: appState.settings.language) { _, _ in appState.warmUpEngine() }
            }
            Section("Output") {
                Picker("When done", selection: $appState.settings.delivery) {
                    ForEach(DeliveryMode.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Play sound cues", isOn: $appState.settings.playSounds)
            }

        }.formStyle(.grouped)
    }

    private var appTab: some View {
        Form {
            Section("App") {
                Toggle("Show in menu bar", isOn: $appState.settings.showMenuBarExtra)
                Toggle("Show Dock icon", isOn: $appState.settings.showDockIcon)
                Toggle("Launch at login", isOn: $appState.settings.launchAtLogin)
            }

            Section("Updates") {
                Toggle("Automatically check for updates",
                       isOn: $updaterService.automaticallyChecksForUpdates)
                CheckForUpdatesButton(updaterService: updaterService)
            }

        }.formStyle(.grouped)
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

                if appState.settings.engine == .whisperKit {
                    Picker("Model", selection: $appState.settings.model) {
                        ForEach(WhisperModel.allCases) { Text($0.displayName).tag($0) }
                    }
                    .onChange(of: appState.settings.model) { _, _ in appState.warmUpEngine() }
                }

                Toggle("Fall back to Apple Speech if the model is unavailable",
                       isOn: $appState.settings.allowAppleFallback)
                if appState.settings.allowAppleFallback || appState.settings.engine == .appleSpeech {
                    Button("Enable Apple Speech access") { Task { _ = await appState.requestSpeechPermission() } }
                }
            }

            if appState.settings.engine == .whisperCLI {
                Section("Whisper CLI") {
                    Text("Use {audio} for the recording and {output} for the output folder.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Command", text: $appState.settings.whisperCommand)
                    TextField("Arguments", text: $appState.settings.whisperArguments)
                }
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
            Label("Preparing \(appState.settings.engine.displayName)…", systemImage: "arrow.down.circle")
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    // MARK: - Vocabulary

    private var vocabularyTab: some View {
        Form {
            Section("Formatting") {
                Toggle("Spoken line commands", isOn: $appState.settings.formatting.spokenLineCommands)
                Text("Say \"new line\" or \"new paragraph\" to insert a line break.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Capitalise sentences", isOn: $appState.settings.formatting.capitalizeSentences)
                Text("Uppercase the first letter of each sentence and line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Remove filler words", isOn: $appState.settings.formatting.removeFillerWords)
                Text("Drop \"um\", \"uh\", \"erm\" and \"uhm\", then tidy the spacing left behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sharedLibrarySection

            Section("Your replacements") {
                Text("Replace recognized words automatically — e.g. fix names or jargon Whisper gets wrong. These apply on top of the shared library and win on conflicts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach($appState.settings.vocabulary.rules) { $rule in
                    HStack {
                        TextField("Heard", text: $rule.find)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Replace with", text: $rule.replaceWith)
                        Button {
                            // Capture the id first: reading `rule` (a Binding into
                            // settings.vocabulary) inside removeAll's mutating closure
                            // overlaps its write access and traps on exclusivity.
                            let ruleID = rule.id
                            appState.settings.vocabulary.rules.removeAll { $0.id == ruleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove replacement")
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

    private var sharedLibrarySection: some View {
        Section("Shared library") {
            Text("Agency-managed client names and phrases refresh automatically and remain available offline.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                sharedStatusView
                Spacer()
                Button("Refresh") { appState.refreshSharedVocabulary() }
            }

            if !appState.sharedVocabulary.rules.isEmpty {
                DisclosureGroup("\(appState.sharedVocabulary.rules.count) shared replacements") {
                    ForEach(appState.sharedVocabulary.rules) { rule in
                        HStack {
                            Text(rule.find)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(rule.replaceWith)
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sharedStatusView: some View {
        switch appState.sharedVocabulary.status {
        case .idle:
            Text("Not configured").font(.caption).foregroundStyle(.secondary)
        case .loading:
            Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        case .loaded(let count, let date):
            VStack(alignment: .leading, spacing: 2) {
                Label("\(count) terms loaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange).lineLimit(1)
        }
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

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case dictation = "Dictation", text = "Text", meetings = "Meetings", app = "App", advanced = "Advanced"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dictation: return "mic"
        case .text: return "textformat"
        case .meetings: return "calendar"
        case .app: return "macwindow"
        case .advanced: return "slider.horizontal.3"
        }
    }
}
