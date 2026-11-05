import SwiftUI
import WhiskerFlowCore

/// One corrections list. Learning is automatic; this screen only explains what
/// was learned and lets the user forget an unwanted correction.
struct DictionaryView: View {
    @Bindable var appState: AppState
    @State private var search = ""

    private var entries: [DictionaryEntry] {
        appState.dictionary.entries.filter { entry in
            search.isEmpty || ([entry.heard, entry.written] + entry.variants).contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted { $0.addedAt > $1.addedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Corrections").font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("Learns from the words you fix, as you use the app.").foregroundStyle(FlowStyle.muted)
                }
                Spacer()
                Toggle("Learn from my corrections", isOn: $appState.settings.rememberCorrections)
                    .toggleStyle(.switch).fixedSize()
                    .onChange(of: appState.settings.rememberCorrections) { _, _ in appState.configureCleanup() }
            }
            Text("Fix a misheard word after pasting, or edit a transcript in History. The local AI checks that it's a recognition error before remembering it. Intentional rewrites aren't saved. Cleanup uses relevant corrections in the context of each transcript.")
                .font(.callout).foregroundStyle(FlowStyle.muted).fixedSize(horizontal: false, vertical: true)
            if !appState.settings.cleanupEnabled {
                Label("Turn on Cleanup in Settings to check and learn corrections locally.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(FlowStyle.muted)
            }
            if let error = appState.dictionary.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(FlowStyle.muted)
                TextField("Search corrections", text: $search).textFieldStyle(.plain)
            }.padding(12).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if entries.isEmpty {
                        FlowEmptyState(symbol: "checkmark.bubble", title: search.isEmpty ? "No corrections yet" : "No matching corrections",
                                       detail: "There's nothing to set up. Corrections appear here automatically when you fix a recognition mistake.")
                    }
                    ForEach(entries) { entry in
                        HStack(spacing: 12) {
                            let heard = entry.kind == .word ? entry.variants.joined(separator: ", ") : entry.heard
                            if !heard.isEmpty {
                                Text(heard).foregroundStyle(FlowStyle.muted)
                                Image(systemName: "arrow.right").foregroundStyle(FlowStyle.muted).font(.caption)
                            }
                            Text(entry.written).fontWeight(.medium)
                            Spacer()
                            Button("Forget") { appState.removeCorrection(entry) }
                                .buttonStyle(.plain).foregroundStyle(FlowStyle.muted)
                                .accessibilityLabel("Forget correction to \(entry.written)")
                        }.padding(14).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            if !appState.hasAccessibilityPermission && appState.settings.rememberCorrections {
                HStack {
                    Text("Allow Accessibility to notice edits to your pasted dictation.").font(.callout)
                    Spacer()
                    Button("Allow Accessibility") { appState.requestAccessibilityPermission() }
                }
            }
            Text("\(appState.dictionary.entries.count) saved corrections. Everything stays on this Mac. Existing saved spellings are kept.")
                .font(.caption).foregroundStyle(FlowStyle.muted)
        }.padding(32)
    }
}
