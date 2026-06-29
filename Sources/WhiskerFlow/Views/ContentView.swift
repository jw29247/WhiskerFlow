import SwiftUI
import WhiskerFlowCore

struct ContentView: View {
    @Bindable var appState: AppState
    @State private var showOnboarding = false
    @State private var showStats = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                StatusHeader(appState: appState) { showOnboarding = true }
                Divider()
                List(selection: $appState.selectedRecordID) {
                    ForEach(appState.filteredRecords) { record in
                        TranscriptRow(record: record)
                            .tag(record.id)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    appState.delete(record)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if appState.records.isEmpty {
                        ContentUnavailableView(
                            "No Transcripts",
                            systemImage: "waveform",
                            description: Text("Hold \(appState.settings.hotkeyDisplayName) to create your first recording.")
                        )
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
            .searchable(text: $appState.searchText, placement: .sidebar, prompt: "Search transcripts")
        } detail: {
            TranscriptDetailView(appState: appState)
                .navigationSplitViewColumnWidth(min: 420, ideal: 560)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showStats = true
                } label: {
                    Label("Stats", systemImage: "chart.bar")
                }
                .help("Dictation stats")
            }
            ToolbarItem {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .onAppear {
            // Synchronous, one-shot startup. Deliberately NOT `.task`: that runs via
            // `Task.immediate`, whose executor check crashes when SwiftUI rebuilds this
            // view during an AppKit reopen event (Dock click / relaunch while running
            // with no window). `.onAppear` avoids the concurrency path; `start()` is
            // idempotent so re-appearing is harmless.
            appState.start()
            applyDockPolicy(appState.settings.showDockIcon)
            if appState.records.isEmpty && !appState.hasAccessibilityPermission {
                showOnboarding = true
            }
        }
        .onChange(of: appState.settings.showDockIcon) { _, newValue in
            applyDockPolicy(newValue)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(appState: appState)
        }
        .sheet(isPresented: $showStats) {
            StatsView(appState: appState)
        }
    }

    private func applyDockPolicy(_ showDock: Bool) {
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
    }
}

private struct TranscriptRow: View {
    let record: TranscriptRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .lineLimit(2)
                    .font(.callout)
                HStack(spacing: 6) {
                    Text(record.createdAt, style: .date)
                    if record.status == .transcribed, record.wordCount > 0 {
                        Text("· \(record.wordCount) words")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var icon: some View {
        switch record.status {
        case .transcribed:
            Image(systemName: "quote.bubble").foregroundStyle(Color.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .transcribing, .recording:
            ProgressView().controlSize(.small)
        }
    }

    private var title: String {
        if !record.text.isEmpty { return record.text }
        switch record.status {
        case .transcribing: return "Transcribing…"
        case .recording: return "Recording…"
        case .failed(let message): return message
        case .transcribed: return "Untitled transcript"
        }
    }
}

/// Compact status + permissions banner shown at the top of the sidebar.
private struct StatusHeader: View {
    @Bindable var appState: AppState
    var openOnboarding: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: appState.isRecording ? "waveform.circle.fill" : "waveform.circle")
                    .font(.title2)
                    .foregroundStyle(appState.isRecording ? .red : .primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WhiskerFlow")
                        .font(.headline)
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

            if !appState.hasAccessibilityPermission || !appState.hasMicrophonePermission {
                Button(action: openOnboarding) {
                    Label("Finish setup", systemImage: "exclamationmark.shield")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }
        }
        .padding(12)
    }
}
