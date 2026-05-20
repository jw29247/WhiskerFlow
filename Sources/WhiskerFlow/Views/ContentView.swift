import SwiftUI
import WhiskerFlowCore

struct ContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selectedRecordID) {
                Section("Transcripts") {
                    ForEach(appState.records) { record in
                        TranscriptRow(record: record)
                            .tag(record.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .toolbar {
                ToolbarItem {
                    Button {
                        appState.refreshDevices()
                    } label: {
                        Label("Refresh Mics", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh Microphones")
                }
            }
        } content: {
            ControlPanelView(appState: appState)
                .navigationSplitViewColumnWidth(min: 360, ideal: 420)
        } detail: {
            TranscriptDetailView(record: appState.selectedRecord) { text in
                appState.paste(text)
            } retry: { record in
                appState.retry(record)
            }
        }
        .background(.regularMaterial)
    }
}

private struct TranscriptRow: View {
    let record: TranscriptRecord

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Text(record.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
    }

    private var title: String {
        if !record.text.isEmpty {
            return record.text
        }

        if case .failed(let message) = record.status {
            return message
        }

        return "Untitled transcript"
    }

    private var icon: String {
        switch record.status {
        case .transcribed:
            "quote.bubble"
        case .failed:
            "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private var color: Color {
        switch record.status {
        case .transcribed:
            .accentColor
        case .failed:
            .orange
        }
    }
}
