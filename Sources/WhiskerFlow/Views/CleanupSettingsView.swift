import SwiftUI
import WhiskerFlowCore

struct CleanupSettingsView: View {
    @Bindable var appState: AppState
    @State private var sample = "I want to do that on Wednesday, no, Thursday at 8 p.m., no, 10 PM."
    @State private var result: CleanupResult?
    @State private var testing = false

    private let model = CleanupModel.gemma2

    var body: some View {
        Form {
            Section("Cleanup") {
                Toggle("Clean up dictation", isOn: $appState.settings.cleanupEnabled)
                    .disabled(!CleanupService.supported || (!appState.cleanup.installed(model) && !appState.settings.cleanupEnabled))
                Text("Removes ums, accidental repeats and spoken self-corrections while keeping your wording and meaning. Runs entirely on this Mac after transcription. The original stays in History when history is enabled.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Cleanup is a preview. Check names, numbers and corrections before sending important text. Literal writing style and voice editing instructions skip Cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Transcripts over 4,000 characters use normal transcription in this preview.")
                    .font(.caption).foregroundStyle(.secondary)
                if !CleanupService.supported {
                    Text("Cleanup needs an Apple silicon Mac with at least 8 GB of memory.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Local model") {
                Text("Gemma 2 2B uses 4-bit weights and needs at least 8 GB of memory. Cleanup checks free memory before loading and pauses under memory pressure. Macs with less than 16 GB release it sooner between dictations.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Selected", value: model.name)
                LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                LabeledContent("Status", value: appState.cleanup.status)
                if appState.cleanup.downloading {
                    ProgressView(value: appState.cleanup.downloadProgress)
                    Button("Cancel download") { appState.cleanup.cancelDownload() }
                } else if !appState.cleanup.installed(model) {
                    Text("Downloading means you agree to Google's Gemma terms and use policy. The model downloads from Hugging Face. Cleanup processes your text on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Link("Gemma terms", destination: URL(string: "https://ai.google.dev/gemma/terms")!)
                        Link("Use policy", destination: URL(string: "https://ai.google.dev/gemma/prohibited_use_policy")!)
                    }
                    Button("Agree and download \(model.name)") {
                        appState.cleanup.download(model) {
                            appState.settings.cleanupEnabled = true
                            appState.configureCleanup()
                        }
                    }.disabled(!CleanupService.supported)
                } else {
                    Button("Download model again") { appState.cleanup.download(model) {} }
                        .disabled(appState.cleanup.running)
                }
                Text("Warms up when you start dictating, then sleeps after \(Int(model.idleSeconds)) seconds without use. Memory pressure releases the model immediately. If Cleanup is unavailable or takes too long, dictation uses the original transcript.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Release model memory now") { appState.cleanup.sleepNow() }
                    .disabled(appState.cleanup.running)
            }

            Section("Try Cleanup") {
                TextEditor(text: $sample).font(.body).frame(minHeight: 75)
                    .accessibilityLabel("Transcript to clean up")
                Button(testing ? "Cleaning up…" : "Clean up this text") {
                    testing = true
                    let input = sample
                    let selected = model
                    Task { @MainActor in
                        result = await appState.cleanup.clean(input, model: selected)
                        testing = false
                    }
                }.disabled(testing || appState.cleanup.running || !appState.settings.cleanupEnabled
                    || !appState.cleanup.installed(model) || sample.isEmpty)
                if let result {
                    Text(result.text).textSelection(.enabled)
                    if ["fallback", "rejected", "skipped"].contains(result.outcome) {
                        Text("Kept the original because Cleanup couldn't safely finish.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.formStyle(.grouped)
    }
}
