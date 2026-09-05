import SwiftUI
import WhiskerFlowCore

struct CorrectionsView: View {
    @Bindable var appState: AppState
    @State private var confirmClear = false

    private var groups: [[SavedCorrection]] {
        Dictionary(grouping: appState.corrections.records, by: \.suggestion).values
            .map { $0.sorted { $0.date > $1.date } }
            .sorted { $0[0].date > $1[0].date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Corrections").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("Small fixes, remembered.").foregroundStyle(FlowStyle.muted)
                }
                Spacer()
                Toggle("Remember corrections", isOn: $appState.settings.rememberCorrections)
                    .toggleStyle(.switch).fixedSize()
            }
            Text("Fix a word after WhiskerFlow pastes it into a supported app. Stay in the text field for a moment and the correction will appear here. Only word changes are saved, on this Mac.")
                .font(.callout).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
            if !appState.hasAccessibilityPermission && appState.settings.rememberCorrections {
                HStack {
                    Label("Allow Accessibility to recognize corrections in other apps.", systemImage: "hand.raised")
                        .font(.callout)
                    Spacer()
                    Button("Allow Accessibility") { appState.requestAccessibilityPermission() }
                }
            }
            if let error = appState.corrections.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if groups.isEmpty {
                FlowEmptyState(symbol: "text.badge.checkmark", title: "Your next correction starts here",
                               detail: "Detected fixes will appear here for review. Add a useful one to vocabulary to improve future dictation.")
            } else {
                HStack {
                    Text("\(groups.count) word \(groups.count == 1 ? "change" : "changes")").font(.system(size: 12, weight: .medium)).foregroundStyle(FlowStyle.muted)
                    Spacer()
                    Button("Clear all", role: .destructive) { confirmClear = true }.buttonStyle(.plain)
                }
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(groups, id: \.first!.id) { group in
                            correctionRow(group)
                        }
                    }
                }
            }
            Text("Watches only the pasted field for up to 2 minutes, while it stays focused. Password fields and apps that don’t expose editable text are skipped. Changes made in History are also remembered. Nothing is applied automatically.")
                .font(.caption).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .alert("Clear saved corrections?", isPresented: $confirmClear) {
            Button("Clear corrections", role: .destructive) { appState.corrections.clear() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the correction history from this Mac. Your vocabulary stays as it is.") }
    }

    private func correctionRow(_ group: [SavedCorrection]) -> some View {
        let record = group[0]
        let applied = appState.settings.vocabulary.rules.contains { $0.find == record.original && $0.replaceWith == record.replacement }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(record.original).foregroundStyle(FlowStyle.muted).strikethrough()
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(FlowStyle.muted)
                Text(record.replacement).fontWeight(.medium).textSelection(.enabled)
                Spacer()
            }.font(.system(size: 16))
            HStack(spacing: 8) {
                Text("\(group.count) \(group.count == 1 ? "time" : "times") · \(record.application) · \(record.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(FlowStyle.muted)
                Spacer()
                Button(applied ? "In vocabulary" : "Add to vocabulary") {
                    appState.acceptVocabularySuggestion(record.suggestion)
                }.disabled(applied)
                Button { appState.corrections.remove(record.suggestion) } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).help("Dismiss correction")
                    .accessibilityLabel("Dismiss \(record.original) to \(record.replacement)")
            }
        }
        .padding(18).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FlowStyle.line, lineWidth: 1))
    }
}
