import AppKit
import SwiftUI
import WhiskerFlowCore

struct HistoryView: View {
    @Bindable var appState: AppState
    @Binding var draft: TranscriptDraft
    let record: TranscriptRecord?
    var save: () -> Bool
    var select: (TranscriptRecord) -> Void
    @State private var showStats = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.system(size: 24, weight: .semibold, design: .rounded))
                Spacer()
                Button { showStats = true } label: { Label("Activity", systemImage: "chart.bar") }
                Menu {
                    Button("Markdown") { export(.markdown) }
                    Button("CSV") { export(.csv) }
                    Button("JSON") { export(.json) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(appState.records.isEmpty)
            }
            .padding(.horizontal, 28).padding(.vertical, 25)
            Divider()
            if appState.records.isEmpty && record == nil {
                FlowEmptyState(symbol: "text.alignleft", title: "Your words, all here.",
                               detail: "Your first dictation will appear here, ready to copy, edit or export.")
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
        .sheet(isPresented: $showStats) { StatsView(appState: appState) }
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

            if appState.filteredRecords.isEmpty {
                FlowEmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Try a different word or clear your search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(appState.filteredRecords) { record in
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
                    }.padding(.horizontal, 10).padding(.bottom, 12)
                }
            }
            Divider()
            Text("\(appState.filteredRecords.count) of \(appState.records.count) saved recordings")
                .font(.system(size: 10)).foregroundStyle(FlowStyle.muted).padding(13)
        }
        .frame(width: 245)
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
