import SwiftUI
import WhiskerFlowCore

struct ContentView: View {
    @Bindable var appState: AppState
    @State private var destination: FlowDestination = UIPreview.screen == "styles" ? .assistant : .dictate
    @State private var draft = TranscriptDraft()
    @State private var selectedSnapshot: TranscriptRecord?
    @State private var pendingNavigation: (() -> Void)?
    @State private var confirmNavigation = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if appState.requiresAtlasSignIn {
            AtlasSignInGate(appState: appState)
                .modifier(OnboardingWindow.Presenter(onboarding: appState.onboarding))
                .onAppear {
                    UIPreview.scheduleSnapshotIfRequested()
                    // Starting watches the dictation key, which now opens this
                    // window; setup follows once signed in.
                    DispatchQueue.main.async {
                        appState.start()
                        appState.applyActivationPolicy()
                    }
                }
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if case .failure(let message) = appState.status {
                    HStack(spacing: 12) {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { appState.status = .idle }.buttonStyle(.plain)
                    }.foregroundStyle(FlowStyle.ink).padding(15).background(FlowStyle.danger.opacity(0.12))
                }
                if let notice = appState.dictionaryNotice {
                    HStack(spacing: 12) {
                        Label(notice.message, systemImage: "character.book.closed").font(.callout)
                        Spacer()
                        Button("Undo") { appState.undoDictionaryNotice() }
                        if destination != .dictionary {
                            Button("View corrections") { navigate { destination = .dictionary } }
                        }
                        Button { appState.dictionaryNotice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss")
                    }.foregroundStyle(FlowStyle.ink).padding(15).background(FlowStyle.selection)
                }
                if let notice = appState.translationNotice {
                    HStack(spacing: 12) {
                        Label(notice, systemImage: "character.bubble").font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Open Settings") { openSettings() }
                        Button { appState.translationNotice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss")
                    }.foregroundStyle(FlowStyle.ink).padding(15).background(FlowStyle.selection)
                }
                if appState.settings.meetingModeChoicePending {
                    // Asked once, after the reset of a setting an earlier update
                    // turned on without asking. Either answer, or a change to the
                    // setting anywhere else, clears it.
                    HStack(alignment: .top, spacing: 12) {
                        Label("Automatic meeting recording is now off. An earlier update turned it on without asking. When it is on, WhiskerFlow starts recording a scheduled Google Meet call as soon as you join it in Chrome, without asking first, and uploads the recording and transcript to Atlas.",
                              systemImage: "calendar.badge.clock")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            Button("Keep it off") { appState.answerAutomaticRecordingNotice(turnOn: false) }
                            Button("Turn on automatic recording") { appState.answerAutomaticRecordingNotice(turnOn: true) }
                        }.fixedSize()
                    }.foregroundStyle(FlowStyle.ink).padding(15).background(FlowStyle.selection)
                }
                switch destination {
                case .dictate:
                    DictationView(appState: appState, openSetup: { appState.onboarding.present() }) { record in
                        navigate {
                            destination = .history
                            select(record ?? appState.records.first)
                        }
                    }
                case .assistant:
                    AssistantView(appState: appState)
                case .meetings:
                    MeetingsView(appState: appState)
                case .dictionary:
                    DictionaryView(appState: appState)
                case .history:
                    HistoryView(appState: appState, draft: $draft, record: currentRecord, save: saveDraft,
                                select: { record in navigate { select(record) } },
                                openInsights: { navigate { destination = .insights } })
                case .insights:
                    InsightsView(appState: appState)
                case .leaderboard:
                    LeaderboardView(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlowStyle.canvas)
        }
        .foregroundStyle(FlowStyle.ink)
        .tint(FlowStyle.accent)
        .background(WindowCloseGuard(isDirty: draft.isDirty, save: saveDraft, discard: { draft.discard() }))
        .focusedSceneValue(\.showScreen, show)
        .focusedSceneValue(\.copyTranscript, destination == .history && currentRecord != nil ? { appState.copyEditorText(draft.text) } : nil)
        .alert("Save your changes?", isPresented: $confirmNavigation) {
            Button("Save changes") {
                if saveDraft() { finishNavigation() }
            }
            Button("Discard changes", role: .destructive) {
                draft.discard()
                finishNavigation()
            }
            Button("Cancel", role: .cancel) { pendingNavigation = nil }
        } message: {
            Text("This transcript has unsaved changes.")
        }
        .modifier(OnboardingWindow.Presenter(onboarding: appState.onboarding))
        .onAppear {
            if let name = UIPreview.destination, let preview = FlowDestination(rawValue: name) { destination = preview }
            UIPreview.scheduleSnapshotIfRequested()
            if UIPreview.settingsCategory != nil { openSettings() }
            UIPreview.writeSettingsSnapshotIfRequested()
            if destination == .history && draft.recordID == nil { select(appState.records.first) }
            DispatchQueue.main.async {
                appState.start()
                appState.applyActivationPolicy()
                guard !appState.onboarding.isPresented else { return }
                appState.onboarding.presentIfNeeded(
                    hasHistory: !appState.records.isEmpty,
                    hadPreviousLaunch: appState.settings.hadPreviousLaunch,
                    permissionsReady: !DictationPresentation(appState: appState).needsSetup
                )
                UIPreview.writeSnapshotIfRequested()
            }
        }
        .onChange(of: appState.settings.showDockIcon) { _, _ in appState.applyActivationPolicy() }
        .onChange(of: appState.records) { _, records in
            if let record = records.first(where: { $0.id == draft.recordID }) {
                selectedSnapshot = record
                draft.synchronize(id: record.id, text: record.text)
            }
        }
    }

    /// A native sidebar list: arrow keys move between screens and VoiceOver
    /// announces the selected one. Choosing a row goes through the
    /// unsaved-edits check, so a cancelled move leaves the selection where it was.
    private var sidebar: some View {
        List(selection: Binding(get: { destination }, set: { item in if let item { show(item) } })) {
            ForEach(FlowDestination.allCases) { item in
                Label {
                    HStack {
                        Text(item.rawValue)
                        Spacer()
                        if item == .meetings && appState.isMeetingCapturing {
                            Circle().fill(FlowStyle.recording).frame(width: 6, height: 6)
                                .accessibilityLabel("Recording")
                        }
                    }
                } icon: {
                    Image(systemName: item.symbol)
                }
                .font(FlowStyle.body)
                .padding(.vertical, 4)
                .tag(item)
                .help("\(item.rawValue) · ⌘\(item.shortcutLabel)")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 9) {
                FlowWaveform(size: 25)
                Text("WhiskerFlow").font(FlowStyle.subheading).tracking(-0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 20)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if appState.isRecording || appState.isTranscribing {
                    FlowStatus(title: DictationPresentation(appState: appState).statusTitle,
                               color: appState.isRecording ? FlowStyle.recording : FlowStyle.accent)
                        .padding(.horizontal, 20).padding(.bottom, 20)
                }
                if UIPreview.isEnabled {
                    Text("UI PREVIEW · SAMPLE DATA").font(FlowStyle.small.weight(.medium)).tracking(0.5)
                        .foregroundStyle(FlowStyle.muted).padding(.horizontal, 18).padding(.bottom, 16)
                }
                Divider()
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .font(FlowStyle.body).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.vertical, 18).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
    }

    /// Opens a screen from the sidebar or the View menu's ⌘1 – ⌘7.
    private func show(_ item: FlowDestination) {
        guard item != destination else { return }
        navigate {
            destination = item
            if item == .history && draft.recordID == nil { select(appState.records.first) }
        }
    }

    private func navigate(_ action: @escaping () -> Void) {
        if draft.isDirty {
            pendingNavigation = action
            confirmNavigation = true
        } else { action() }
    }

    private func finishNavigation() {
        let action = pendingNavigation
        pendingNavigation = nil
        action?()
    }

    private func select(_ record: TranscriptRecord?) {
        guard let record else { return }
        if draft.select(id: record.id, text: record.text) {
            selectedSnapshot = record
            appState.selectedRecordID = record.id
        }
    }

    private var currentRecord: TranscriptRecord? {
        appState.records.first(where: { $0.id == draft.recordID })
            ?? (selectedSnapshot?.id == draft.recordID ? selectedSnapshot : nil)
    }

    private func saveDraft() -> Bool {
        guard draft.isDirty else { return true }
        guard let record = currentRecord,
              let saved = appState.saveEditedTranscript(record, text: draft.text) else {
            appState.status = .failure("Your edits couldn’t be saved. They are still here; please try again.")
            return false
        }
        draft.didSave()
        draft.select(id: saved.id, text: saved.text)
        selectedSnapshot = saved
        appState.selectedRecordID = saved.id
        return true
    }

}

enum FlowDestination: String, CaseIterable, Identifiable {
    case dictate = "Dictate", meetings = "Meetings", history = "History", dictionary = "Corrections", assistant = "Assistant",
         insights = "Insights", leaderboard = "Leaderboard"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .assistant: return "wand.and.stars"; case .dictate: return "mic"; case .meetings: return "calendar"; case .history: return "clock.arrow.circlepath"; case .dictionary: return "character.book.closed"; case .insights: return "chart.bar.xaxis"; case .leaderboard: return "trophy" }
    }
    var shortcut: KeyEquivalent {
        switch self { case .assistant: return "5"; case .dictate: return "1"; case .meetings: return "2"; case .history: return "3"; case .dictionary: return "4"; case .insights: return "6"; case .leaderboard: return "7" }
    }
    var shortcutLabel: String {
        switch self { case .assistant: return "5"; case .dictate: return "1"; case .meetings: return "2"; case .history: return "3"; case .dictionary: return "4"; case .insights: return "6"; case .leaderboard: return "7" }
    }
    /// "⌘1 – ⌘7": every screen's shortcut, for the setup's Done step.
    static var shortcutRangeLabel: String {
        let labels = allCases.map(\.shortcutLabel).sorted()
        return "⌘\(labels.first ?? "") – ⌘\(labels.last ?? "")"
    }
}
