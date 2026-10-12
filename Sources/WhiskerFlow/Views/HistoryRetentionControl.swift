import SwiftUI
import WhiskerFlowCore

/// The history-retention choice, shared by Settings and History. A shorter
/// period is only applied after the user confirms how many transcripts go.
struct HistoryRetentionControl: View {
    enum Presentation { case form, menu }

    @Bindable var appState: AppState
    var presentation: Presentation = .form
    @State private var pending: HistoryRetention?
    @State private var pendingCount = 0

    var body: some View {
        control
            .alert(alertTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button(pendingCount > 0 ? "Delete \(transcriptCount(pendingCount))" : "Change", role: pendingCount > 0 ? .destructive : nil) {
                    if let pending { appState.setHistoryRetention(pending) }
                    pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: {
                Text(alertMessage)
            }
    }

    @ViewBuilder
    private var control: some View {
        switch presentation {
        case .form:
            Picker("Keep history", selection: selection) {
                ForEach(HistoryRetention.allCases) { Text($0.displayName).tag($0) }
            }
        case .menu:
            Menu {
                Picker("Keep history", selection: selection) {
                    ForEach(HistoryRetention.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.inline)
            } label: {
                Label(menuTitle, systemImage: "clock.badge.checkmark")
            }
            .fixedSize()
            .help("How long WhiskerFlow keeps your transcripts")
        }
    }

    private var menuTitle: String {
        switch appState.settings.historyRetention {
        case .forever: return "Keeping forever"
        case .off: return "History off"
        case let other: return "Keeping \(other.displayName)"
        }
    }

    private var selection: Binding<HistoryRetention> {
        Binding(get: { appState.settings.historyRetention }, set: request)
    }

    private func request(_ retention: HistoryRetention) {
        let current = appState.settings.historyRetention
        guard retention != current else { return }
        guard current.isLonger(than: retention) else {
            appState.setHistoryRetention(retention)
            return
        }
        pendingCount = appState.historyRemovalCount(for: retention)
        pending = retention
    }

    private var alertTitle: String {
        guard let pending else { return "" }
        if pending == .off { return "Stop saving history?" }
        return "Keep history for \(pending.displayName)?"
    }

    private var alertMessage: String {
        guard let pending else { return "" }
        let insightsNote = "Your Insights are kept."
        if pendingCount == 0 {
            return pending == .off
                ? "New dictations will still be pasted, but not saved. \(insightsNote)"
                : "Nothing is old enough to delete yet. Older transcripts will be deleted as they pass \(pending.displayName). \(insightsNote)"
        }
        let what = pending == .off ? "\(transcriptCount(pendingCount)) from History" : "\(transcriptCount(pendingCount)) older than \(pending.displayName)"
        return "This permanently deletes \(what). \(insightsNote)"
    }

    private func transcriptCount(_ count: Int) -> String {
        count == 1 ? "1 transcript" : "\(count.formatted()) transcripts"
    }
}
