import SwiftUI
import WhiskerFlowCore

struct ContentView: View {
    @Bindable var appState: AppState
    @State private var destination: FlowDestination = .dictate
    @State private var showOnboarding = false
    @State private var draft = TranscriptDraft()
    @State private var selectedSnapshot: TranscriptRecord?
    @State private var pendingNavigation: (() -> Void)?
    @State private var confirmNavigation = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(FlowStyle.line).frame(width: 1)
            VStack(spacing: 0) {
                if case .failure(let message) = appState.status {
                    HStack(spacing: 12) {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { appState.status = .idle }.buttonStyle(.plain)
                    }.foregroundStyle(FlowStyle.ink).padding(15).background(Color.orange.opacity(0.12))
                }
                switch destination {
                case .dictate:
                    DictationView(appState: appState, openSetup: { showOnboarding = true }) { record in
                        navigate {
                            destination = .history
                            select(record ?? appState.records.first)
                        }
                    }
                case .assistant:
                    AssistantView(appState: appState)
                case .meetings:
                    MeetingsView(appState: appState)
                case .corrections:
                    CorrectionsView(appState: appState)
                case .history:
                    HistoryView(appState: appState, draft: $draft, record: currentRecord, save: saveDraft) { record in
                        navigate { select(record) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlowStyle.canvas)
        }
        .foregroundStyle(FlowStyle.ink)
        .tint(FlowStyle.accent)
        .background(WindowCloseGuard(isDirty: draft.isDirty, save: saveDraft, discard: { draft.discard() }))
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
        .sheet(isPresented: $showOnboarding) { OnboardingView(appState: appState) }
        .onAppear {
            DispatchQueue.main.async {
                appState.start()
                appState.applyActivationPolicy()
                if appState.records.isEmpty && DictationPresentation(appState: appState).needsSetup {
                    showOnboarding = true
                }
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                FlowWaveform(size: 25)
                Text("WhiskerFlow").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.6)
            }
            .padding(.horizontal, 25).padding(.top, 32).padding(.bottom, 42)

            VStack(spacing: 8) {
                ForEach(FlowDestination.allCases) { item in
                    Button {
                        navigate {
                            destination = item
                            if item == .history && draft.recordID == nil { select(appState.records.first) }
                        }
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: item.symbol).font(.system(size: 18, weight: .regular)).frame(width: 23)
                            Text(item.rawValue).font(.system(size: 14, weight: destination == item ? .medium : .regular))
                            Spacer()
                            if item == .meetings && appState.isMeetingCapturing {
                                Circle().fill(FlowStyle.recording).frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 15).padding(.vertical, 14)
                        .contentShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(destination == item ? FlowStyle.accent : FlowStyle.ink)
                    .background(destination == item ? FlowStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityAddTraits(destination == item ? .isSelected : [])
                    .keyboardShortcut(item.shortcut, modifiers: .command)
                    .help("\(item.rawValue) · ⌘\(item.shortcutLabel)")
                }
            }.padding(.horizontal, 16)
            Spacer(minLength: 30)
            if appState.isRecording || appState.isTranscribing {
                FlowStatus(title: DictationPresentation(appState: appState).statusTitle,
                           color: appState.isRecording ? FlowStyle.recording : FlowStyle.accent)
                    .padding(.horizontal, 28).padding(.bottom, 20)
            }
            if UIPreview.isEnabled {
                Text("UI PREVIEW · SAMPLE DATA").font(.system(size: 9, weight: .medium)).tracking(0.5)
                    .foregroundStyle(FlowStyle.muted).padding(.horizontal, 25).padding(.bottom, 16)
            }
            Divider()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 27).padding(.vertical, 25).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
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
            appState.dismissVocabularySuggestions()
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

private enum FlowDestination: String, CaseIterable, Identifiable {
    case dictate = "Dictate", meetings = "Meetings", history = "History", corrections = "Corrections", assistant = "Assistant"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .assistant: return "wand.and.stars"; case .dictate: return "mic"; case .meetings: return "calendar"; case .history: return "clock.arrow.circlepath"; case .corrections: return "text.badge.checkmark" }
    }
    var shortcut: KeyEquivalent {
        switch self { case .assistant: return "5"; case .dictate: return "1"; case .meetings: return "2"; case .history: return "3"; case .corrections: return "4" }
    }
    var shortcutLabel: String {
        switch self { case .assistant: return "5"; case .dictate: return "1"; case .meetings: return "2"; case .history: return "3"; case .corrections: return "4" }
    }
}
