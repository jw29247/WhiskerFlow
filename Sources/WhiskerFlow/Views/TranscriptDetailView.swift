import SwiftUI
import WhiskerFlowCore

struct TranscriptDetailView: View {
    @Bindable var appState: AppState

    @State private var draft: String = ""
    @State private var editingID: TranscriptRecord.ID?

    private var record: TranscriptRecord? { appState.selectedRecord }

    var body: some View {
        Group {
            if let record {
                content(for: record)
            } else {
                ContentUnavailableView(
                    "No Transcripts",
                    systemImage: "waveform",
                    description: Text("Hold \(appState.settings.hotkey.displayName) to create your first recording.")
                )
            }
        }
        .background(.thinMaterial)
        .onChange(of: record?.id) { _, _ in syncDraft() }
        .onAppear { syncDraft() }
    }

    private func content(for record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(statusTitle(record), systemImage: statusIcon(record))
                    .font(.headline)
                    .foregroundStyle(statusColor(record))
                Spacer()
                actions(for: record)
            }

            metadata(for: record)

            if record.status == .transcribed {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .serif))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.5)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if draft != record.text {
                    HStack {
                        Spacer()
                        Button("Revert") { draft = record.text }
                        Button("Save changes") { appState.updateText(record, to: draft) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ScrollView {
                    Text(detailText(record))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func actions(for record: TranscriptRecord) -> some View {
        if record.status.isFailed {
            Button {
                appState.retry(record)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        Button {
            appState.copy(draft.isEmpty ? record.text : draft)
        } label: {
            Label("Copy", systemImage: "doc.on.clipboard")
        }
        .disabled(record.text.isEmpty)

        Menu {
            Button(role: .destructive) {
                appState.delete(record)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func metadata(for record: TranscriptRecord) -> some View {
        HStack(spacing: 12) {
            Text(record.createdAt, format: .dateTime.weekday().month().day().hour().minute())
            if let duration = record.durationSeconds, duration > 0 {
                Label(durationString(duration), systemImage: "clock")
            }
            if record.status == .transcribed {
                Label("\(record.wordCount) words", systemImage: "text.word.spacing")
            }
            if let engine = record.engine, let kind = TranscriptionEngineKind(rawValue: engine) {
                Label(shortEngineName(kind), systemImage: "cpu")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Helpers

    private func syncDraft() {
        guard let record else { draft = ""; return }
        if editingID != record.id {
            draft = record.text
            editingID = record.id
        }
    }

    private func statusTitle(_ record: TranscriptRecord) -> String {
        switch record.status {
        case .transcribed: return "Transcribed"
        case .failed: return "Queued for retry"
        case .transcribing: return "Transcribing…"
        case .recording: return "Recording…"
        }
    }

    private func statusIcon(_ record: TranscriptRecord) -> String {
        switch record.status {
        case .transcribed: return "checkmark.seal.fill"
        case .failed: return "exclamationmark.triangle"
        case .transcribing, .recording: return "waveform"
        }
    }

    private func statusColor(_ record: TranscriptRecord) -> Color {
        switch record.status {
        case .transcribed: return .green
        case .failed: return .orange
        case .transcribing, .recording: return .secondary
        }
    }

    private func detailText(_ record: TranscriptRecord) -> String {
        if !record.text.isEmpty { return record.text }
        if case .failed(let message) = record.status { return message }
        return "Working…"
    }

    private func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%01d:%02d", total / 60, total % 60)
    }

    private func shortEngineName(_ kind: TranscriptionEngineKind) -> String {
        switch kind {
        case .whisperKit: return "WhisperKit"
        case .appleSpeech: return "Apple Speech"
        case .whisperCLI: return "Whisper CLI"
        }
    }
}
