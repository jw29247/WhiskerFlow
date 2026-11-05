import SwiftUI
import WhiskerFlowCore

struct LocalCleanupSettingsSection: View {
    @Bindable var appState: AppState
    @State private var input = "um can you send the proposal on Tuesday sorry Thursday and uh make sure Sarah gets a copy"
    @State private var output = ""
    @State private var testing = false

    private var cleanup: LocalCleanupController { appState.localCleanup }
    private var captureBusy: Bool { appState.isRecording || appState.isTranscribing || appState.isMeetingCapturing }

    var body: some View {
        Section("AI cleanup") {
            Toggle("Clean up dictation on this Mac", isOn: $appState.settings.localCleanupEnabled)
                .onChange(of: appState.settings.localCleanupEnabled) { _, enabled in
                    if enabled { cleanup.prepare(download: true) } else { cleanup.disable() }
                }
            Text("Removes filler phrases, resolves spoken corrections and fixes grammar before pasting. Uses a small Gemma model entirely on this Mac. Literal styles keep the original wording. Enabled by default; you can turn it off here.")
                .font(.caption).foregroundStyle(.secondary)

            modelControls
            Text("Gemma 4 E2B · downloads 2.59 GB once in the background when cleanup is enabled. Audio and text stay on this Mac. While preparing, or if cleanup takes over 15 seconds, dictation uses the usual text.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Model details and Apache 2.0 license", destination: URL(string: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm")!)
                .font(.caption)

            DisclosureGroup("Try cleanup without recording") {
                Text("Try a messy transcript, or dictate with the switch above on and compare the original recognition in History.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $input)
                    .font(.body).frame(minHeight: 70, maxHeight: 110)
                    .accessibilityLabel("Original transcript")
                HStack {
                    Button(testing ? "Cleaning…" : "Test cleanup") {
                        testing = true
                        let submitted = input
                        Task { @MainActor in
                            output = await appState.previewLocalCleanup(submitted)
                            testing = false
                        }
                    }
                    .disabled(testing || cleanup.state != .ready || captureBusy || input.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                }
                if !output.isEmpty {
                    Text(output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Cleaned transcript")
                }
            }
            if let result = cleanup.lastResult {
                Label("\(result.message) (\(result.seconds, specifier: "%.1f") s)",
                      systemImage: result.applied ? "checkmark.circle" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var modelControls: some View {
        switch cleanup.state {
        case .notDownloaded:
            Button("Download cleanup model (2.59 GB)") { cleanup.prepare(download: true) }
                .disabled(captureBusy)
        case .downloaded:
            Button("Load cleanup model") { cleanup.prepare() }.disabled(captureBusy)
        case .downloading(let fraction):
            ProgressView("Downloading cleanup model · \(Int(fraction * 100))%", value: fraction)
            Button("Cancel download") { cleanup.cancelPreparation() }
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Preparing cleanup model…") }
        case .ready:
            Label("Cleanup model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.orange)
            Button("Retry model setup") { cleanup.prepare(download: true) }.disabled(captureBusy)
        }
    }
}
