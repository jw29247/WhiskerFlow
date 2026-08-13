import SwiftUI
import WhiskerFlowCore

struct SettingsView: View {
    @Bindable var appState: AppState
    @ObservedObject var updaterService: UpdaterService

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
        .frame(width: 600, height: 640)
    }

    // MARK: - General

    private var generalTab: some View {
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
                Text("Transcribe while you speak so the text pastes the instant you release the key. Uses the WhisperKit engine.")
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

            Section("Meeting Mode") {
                Toggle("Automatically capture scheduled meetings", isOn: $appState.settings.meetingModeEnabled)
                    .onChange(of: appState.settings.meetingModeEnabled) { _, _ in
                        appState.refreshMeetingConfiguration()
                    }
                Text("Atlas server: atlas.thatworks.agency")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    appState.signInToAtlas()
                } label: {
                    Label(
                        appState.isSigningInToAtlas ? "Opening Atlas…" : "Sign in with Atlas",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                }
                .disabled(appState.isSigningInToAtlas)
                if let confirmation = appState.atlasSignInConfirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let error = appState.atlasSignInError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Label(
                        appState.meetingStatus.displayName,
                        systemImage: appState.meetingStatus == .covered ? "checkmark.circle.fill" : "exclamationmark.triangle"
                    )
                    .foregroundStyle(appState.meetingStatus == .covered ? .green : .orange)
                    Spacer()
                    Button("Re-check") { appState.refreshMeetingConfiguration() }
                }
                Text("Capture is local-first: network failures leave encrypted chunks queued on this Mac. Audio is never sent to cloud speech recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                meetingHub
            }

            Section("Output") {
                Picker("When done", selection: $appState.settings.delivery) {
                    ForEach(DeliveryMode.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Play sound cues", isOn: $appState.settings.playSounds)
            }

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

            if let persistenceError = appState.settings.persistenceError {
                Section {
                    Label(persistenceError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var meetingHub: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Meeting Hub", systemImage: "calendar.badge.clock")
                    .font(.headline)
                Spacer()
                Button("Refresh") { appState.refreshMeetingSchedule() }
                    .disabled(!appState.isAtlasPaired)
            }

            Button {
                appState.toggleMeetingCapture()
            } label: {
                Label(
                    appState.isMeetingCapturing ? "Stop recording" : "Start ad hoc recording",
                    systemImage: appState.isMeetingCapturing ? "stop.circle.fill" : "record.circle"
                )
            }
            .disabled(!appState.isAtlasPaired && !appState.isMeetingCapturing)

            if appState.upcomingMeetings.isEmpty {
                Text("No upcoming Atlas meetings in the next 7 days.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Upcoming · next 7 days")
                    .font(.subheadline.weight(.semibold))
                ForEach(appState.upcomingMeetings, id: \.eventID) { intent in
                    meetingRow(intent, isPrevious: false)
                }
            }

            if !appState.previousMeetings.isEmpty {
                Text("Previous · last 7 days")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                ForEach(appState.previousMeetings, id: \.eventID) { intent in
                    meetingRow(intent, isPrevious: true)
                }
            }
        }
        .padding(.top, 4)
    }

    private func meetingRow(_ intent: AtlasCaptureScheduleIntent, isPrevious: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isPrevious ? "clock.arrow.circlepath" : "calendar")
                .foregroundStyle(isPrevious ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(intent.title)
                    .lineLimit(1)
                Text(Self.meetingDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(intent.startMs) / 1_000)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isPrevious {
                Text(intent.existingMeetingID == nil ? "Not recorded" : "In Atlas")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if appState.isMeetingCapturing && appState.activeMeetingTitle == intent.title {
                Text("Recording")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Button("Record") { appState.recordScheduledMeeting(intent) }
                    .disabled(appState.isMeetingCapturing || !appState.isAtlasPaired)
            }
        }
        .padding(.vertical, 2)
    }

    private static let meetingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

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
                .onChange(of: appState.settings.language) { _, _ in appState.warmUpEngine() }

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
