import AppKit
import SwiftUI
import WhiskerFlowCore

struct HistoryView: View {
    @Bindable var appState: AppState
    @Binding var draft: TranscriptDraft
    let record: TranscriptRecord?
    var save: () -> Bool
    var select: (TranscriptRecord) -> Void
    var openInsights: () -> Void
    /// History can hold tens of thousands of transcripts; rows are added a page
    /// at a time as the list scrolls.
    @State private var visibleLimit = Self.pageSize
    @FocusState private var searchFocused: Bool
    private static let pageSize = 200

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.system(size: 24, weight: .semibold, design: .rounded))
                Spacer()
                HistoryRetentionControl(appState: appState, presentation: .menu)
                Button { openInsights() } label: { Label("Insights", systemImage: "chart.bar.xaxis") }
                Menu {
                    Button("Markdown") { export(.markdown) }
                    Button("CSV") { export(.csv) }
                    Button("JSON") { export(.json) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(appState.records.isEmpty)
            }
            .padding(.horizontal, 28).padding(.vertical, 25)
            Divider()
            if !appState.settings.historyRetention.savesTranscripts {
                Label("History is off. Dictations are still pasted, and your latest one can be copied for a few minutes, but nothing is saved.",
                      systemImage: "eye.slash")
                    .font(.callout).foregroundStyle(FlowStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(FlowStyle.selection.opacity(0.6))
            }
            if appState.records.isEmpty && record == nil {
                FlowEmptyState(symbol: "text.alignleft", title: "Your words, all here.",
                               detail: appState.settings.historyRetention.savesTranscripts
                                   ? "Your first dictation will appear here, ready to copy, edit or export."
                                   : "Choose how long to keep history from the menu above to start saving transcripts.")
            } else {
                HStack(spacing: 0) {
                    transcriptList
                    Divider()
                    if let record {
                        TranscriptDetailView(appState: appState, record: record, draft: $draft, saveDraft: save)
                            .id(record.id)
                    } else {
                        FlowEmptyState(symbol: "text.cursor", title: "Choose a transcript", detail: "Select a recording to read or edit your words.")
                    }
                }
            }
        }
    }

    private var transcriptList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(FlowStyle.muted)
                TextField("Search transcripts", text: $appState.searchText)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search transcripts")
                if !appState.searchText.isEmpty {
                    Button { appState.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                }
            }
            .padding(11).background(FlowStyle.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(FlowStyle.line, lineWidth: 1))
            .padding(15)

            let filtered = appState.filteredRecords
            if filtered.isEmpty {
                FlowEmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Try a different word or clear your search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filtered.prefix(visibleLimit)) { record in
                            Button { select(record) } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack(spacing: 6) {
                                        Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        Spacer(minLength: 2)
                                        if record.status.isFailed { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                                        if record.status.isInProgress { ProgressView().controlSize(.mini) }
                                        if record.id == draft.recordID && draft.isDirty {
                                            Circle().fill(FlowStyle.accent).frame(width: 5, height: 5).accessibilityLabel("Unsaved changes")
                                        }
                                    }.font(.system(size: 10)).foregroundStyle(FlowStyle.muted)
                                    Text(title(record)).font(.system(size: 13)).lineLimit(3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(13).contentShape(RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                            .background(record.id == draft.recordID ? FlowStyle.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityAddTraits(record.id == draft.recordID ? .isSelected : [])
                        }
                        if filtered.count > visibleLimit {
                            ProgressView().controlSize(.small).padding(10)
                                .onAppear { visibleLimit += Self.pageSize }
                        }
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }
            }
            Divider()
            Text("\(filtered.count.formatted()) of \(appState.records.count.formatted()) saved recordings")
                .font(.system(size: 10)).foregroundStyle(FlowStyle.muted).padding(13)
        }
        .frame(width: 245)
        .onChange(of: appState.searchText) { _, _ in visibleLimit = Self.pageSize }
        .background(FlowStyle.surface.opacity(0.35))
        .background {
            Button("Find transcript") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    private func title(_ record: TranscriptRecord) -> String {
        if !record.text.isEmpty { return record.text }
        switch record.status {
        case .recording: return "Recording…"
        case .transcribing: return "Transcribing…"
        case .failed: return "Transcription needs another try"
        case .transcribed: return "Empty transcript"
        }
    }

    private func export(_ format: TranscriptExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WhiskerFlow History.\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try appState.exportHistory(as: format).write(to: url, options: .atomic) }
        catch { appState.status = .failure("Could not export history") }
    }
}
