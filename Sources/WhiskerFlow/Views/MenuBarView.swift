import AppKit
import SwiftUI
import WhiskerFlowCore

struct MenuBarView: View {
    @Bindable var appState: AppState
    @ObservedObject var updaterService: UpdaterService
    @Environment(\.openWindow) private var openWindow

    private var recents: [TranscriptRecord] {
        appState.records.filter { $0.status == .transcribed }.prefix(3).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: appState.isRecording ? "waveform.circle.fill" : "waveform.circle")
                    .font(.title2)
                    .foregroundStyle(appState.isRecording ? .red : .primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WhiskerFlow").font(.headline)
                    Text(appState.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if appState.isRecording {
                    LevelMeter(level: appState.audioLevel)
                } else if appState.isTranscribing {
                    ProgressView().controlSize(.small)
                }
            }

            if !recents.isEmpty {
                Divider()
                Text("Recent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(recents) { record in
                    Button {
                        appState.copy(record.text)
                    } label: {
                        Text(record.text)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                }
            }

            if appState.retryQueue.count > 0 {
                Divider()
                Button {
                    appState.retryAllFailed()
                } label: {
                    Label("Retry \(appState.retryQueue.count) failed", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            Divider()
            Button("Open WhiskerFlow") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .buttonStyle(.plain)

            SettingsLink {
                Text("Settings…")
            }
            .buttonStyle(.plain)

            CheckForUpdatesButton(updaterService: updaterService)
                .buttonStyle(.plain)

            Button("Quit WhiskerFlow") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 290)
    }
}
