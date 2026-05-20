import SwiftUI
import WhiskerFlowCore

struct TranscriptDetailView: View {
    let record: TranscriptRecord?
    let paste: (String) -> Void
    let retry: (TranscriptRecord) -> Void

    var body: some View {
        Group {
            if let record {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Label(statusTitle(for: record), systemImage: statusIcon(for: record))
                            .font(.headline)
                            .foregroundStyle(statusColor(for: record))

                        Spacer()

                        if case .failed = record.status {
                            Button {
                                retry(record)
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button {
                            paste(record.text)
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        .disabled(record.text.isEmpty)
                    }

                    Text(record.createdAt, format: .dateTime.weekday().month().day().hour().minute())
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(detailText(for: record))
                            .font(.system(.body, design: .serif))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recording")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(record.audioFilePath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    "No Transcripts",
                    systemImage: "waveform",
                    description: Text("Hold fn to create your first recording.")
                )
            }
        }
        .background(.thinMaterial)
    }

    private func statusTitle(for record: TranscriptRecord) -> String {
        switch record.status {
        case .transcribed:
            "Transcribed"
        case .failed:
            "Queued for Retry"
        }
    }

    private func statusIcon(for record: TranscriptRecord) -> String {
        switch record.status {
        case .transcribed:
            "checkmark.seal.fill"
        case .failed:
            "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private func statusColor(for record: TranscriptRecord) -> Color {
        switch record.status {
        case .transcribed:
            .green
        case .failed:
            .orange
        }
    }

    private func detailText(for record: TranscriptRecord) -> String {
        if !record.text.isEmpty {
            return record.text
        }

        if case .failed(let message) = record.status {
            return message
        }

        return "No transcript text yet."
    }
}
