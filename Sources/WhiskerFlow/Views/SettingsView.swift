import AVFoundation
import SwiftUI
import WhiskerFlowAppSupport
import WhiskerFlowCore

struct SettingsView: View {
    @Bindable var appState: AppState
    @ObservedObject var updaterService: UpdaterService
    @State private var category: SettingsCategory = UIPreview.settingsCategory.flatMap(SettingsCategory.init) ?? .dictation

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
                    case .history: historyTab
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

                Toggle("Pause media while dictating", isOn: $appState.settings.pauseMediaWhileDictating)
                Text("Pauses music or video when you start dictating and plays it again when you stop. Nothing happens if nothing is playing or you're in a call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Live transcription", isOn: $appState.settings.liveTranscription)
                Text("Show what's being heard in the recording panel while you speak. The pasted text still comes from a full pass when you finish.")
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

            Section("Setup") {
                LabeledContent("First-run setup") { RunSetupAgainButton(appState: appState) }
                Text("Walks through permissions, your microphone, shortcut and a practice dictation again.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates",
                       isOn: $updaterService.automaticallyChecksForUpdates)
                CheckForUpdatesButton(updaterService: updaterService)
            }

        }.formStyle(.grouped)
    }

    // MARK: - History

    @State private var confirmResetInsights = false

    private var historyTab: some View {
        Form {
            Section("Transcript history") {
                HistoryRetentionControl(appState: appState)
                Text(appState.settings.historyRetention.savesTranscripts
                     ? "Older transcripts are deleted automatically. Recordings that failed to transcribe are kept until they are retried or expire."
                     : "Dictations are still pasted, and the latest can be copied for a few minutes, but no transcript is saved. Failed recordings are kept for 24 hours so you can retry them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Recordings") {
                Toggle("Keep recordings for 14 days", isOn: Binding(get: { appState.settings.keepRecentRecordings },
                                                                    set: { appState.setKeepRecentRecordings($0) }))
                Text(appState.settings.keepRecentRecordings
                     ? "The audio of every dictation from the last 14 days stays on this Mac, so you can play it back or transcribe it again with another engine in History."
                     : "Only the audio of your 25 most recent dictations is kept, for up to 30 days. Turn this on to keep every recording from the last 14 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Insights") {
                Stepper(value: Binding(get: { appState.settings.typingWordsPerMinute }, set: { appState.setTypingSpeed($0) }),
                        in: InsightsSummary.typingWordsPerMinuteRange, step: 5) {
                    LabeledContent("Your typing speed", value: "\(appState.settings.typingWordsPerMinute) wpm")
                }
                Text("Insights keep counts only — words, speaking time, app and engine — never transcript text. They stay on this Mac and are kept whatever the history setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset insights…", role: .destructive) { confirmResetInsights = true }
                    .disabled(appState.insightsSummary.isEmpty)
            }
        }
        .formStyle(.grouped)
        .alert("Reset insights?", isPresented: $confirmResetInsights) {
            Button("Reset insights", role: .destructive) { appState.resetInsights() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your word counts, speed, streaks and activity start again from zero. History is not affected.")
        }
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

                Toggle("Fall back to Apple Speech if the model is unavailable",
                       isOn: $appState.settings.allowAppleFallback)
                if appState.settings.allowAppleFallback || appState.settings.engine == .appleSpeech {
                    Button("Enable Apple Speech access") { Task { _ = await appState.requestSpeechPermission() } }
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

                Text("Capitalisation and end punctuation follow each app category's tone in Assistant → Styles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Remove filler words", isOn: $appState.settings.formatting.removeFillerWords)
                Text("Drop \"um\", \"uh\", \"erm\" and \"uhm\", then tidy the spacing left behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            sharedLibrarySection

            Section("Your dictionary") {
                Text("Words and replacements now live in the Dictionary (⌘4 in the main window), with learned suggestions, usage and CSV import/export. \(appState.dictionary.entries.count) personal \(appState.dictionary.entries.count == 1 ? "entry" : "entries").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recogniser hints") {
                Text("Tell the speech recogniser which Dictionary words to expect, before any replacements run. Replacements still apply afterwards either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Apple Speech", isOn: $appState.settings.biasAppleSpeech)
                Text("Passes Words and the written side of Replacements as contextual phrases (up to 100).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Parakeet", isOn: $appState.settings.biasParakeet)
                    .onChange(of: appState.settings.biasParakeet) { _, enabled in
                        if enabled { appState.warmUpEngine() }
                    }
                Text("Rescores the transcript against a separate 98 MB English-only model, downloaded once. Adds about 0.2 s and can occasionally swap in the wrong term.")
                    .font(.caption).foregroundStyle(.secondary)
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
    case dictation = "Dictation", text = "Text", history = "History", meetings = "Meetings", app = "App", advanced = "Advanced"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dictation: return "mic"
        case .text: return "textformat"
        case .history: return "clock.arrow.circlepath"
        case .meetings: return "calendar"
        case .app: return "macwindow"
        case .advanced: return "slider.horizontal.3"
        }
    }
}
